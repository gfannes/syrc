const std = @import("std");
const prot = @import("../prot.zig");
const fs = @import("../fs.zig");
const blob = @import("../blob.zig");
const crypto = @import("../crypto.zig");
const rubr = @import("../rubr.zig");
const Env = rubr.Env;
const Io = @import("Io.zig");

const Self = @This();

pub const Error = error{
    ExpectedHello,
    ExpectedSync,
    ExpectedRun,
    ExpectedBye,
    ExpectedChecksum,
    ExpectedEqualLen,
    ExpectedFileState,
    ExpectedString,
    ExpectedContent,
    EmptySubdir,
    BaseAlreadySet,
    BaseNotSet,
    UnknownId,
    VersionMismatch,
    PeerGaveUp,
    OnlyRelativePathAllowed,
    CouldNotExtractFile,
    SyncToRootNotSupportedYet,
    ExpectedStatusOk,
};

env: Env,
store: *blob.Store,
base: []const u8,

stream: ?std.Io.net.Stream = null,
cio: Io = undefined,
maybe_cmd: ?[]const u8 = null,
args: []const []const u8 = &.{},

maybe_stdout: ?std.Io.File = null,
maybe_stderr: ?std.Io.File = null,
mutex: std.Thread.Mutex = .{},

pub fn init(self: *Self, stream: std.Io.net.Stream) !void {
    self.stream = stream;
    self.cio = Io{ .env = self.env };
    self.cio.init(stream);
}

pub fn deinit(self: *Self) void {
    if (self.stream) |*stream|
        stream.close(self.env.io);
}

pub fn runClient(self: *Self, name: ?[]const u8, reset_folder: bool, cleanup_folder: bool, reset_store: bool, collect: bool) !void {
    var bye = prot.Bye.init(self.env.a);
    defer bye.deinit();

    // Handshake
    {
        try self.cio.send(prot.Hello{ .role = .Client, .status = .Pending });

        var hello: prot.Hello = undefined;
        if (try self.cio.receive2(&hello, &bye)) {
            if (self.env.log.level(1)) |w|
                prot.printMessage(hello, w, null);
            if (hello.status != .Ok) {
                try bye.setReason("Expected status Ok, not {}", .{hello.status});
                try self.cio.send(bye);
                return Error.ExpectedStatusOk;
            }
        } else {
            if (self.env.log.level(1)) |w|
                prot.printMessage(bye, w, null);
            return Error.PeerGaveUp;
        }
    }

    // Sync
    {
        var sync = prot.Sync.init(self.env.a);
        defer sync.deinit();

        if (name) |str|
            sync.subdir = try sync.a.dupe(u8, str);
        sync.reset_folder = reset_folder;
        sync.cleanup_folder = cleanup_folder;
        sync.reset_store = reset_store;
        if (self.env.log.level(1)) |w|
            prot.printMessage(sync, w, null);

        try self.cio.send(sync);

        try self.sendFolderToPeer(self.base);
    }

    // Run
    if (self.maybe_cmd) |cmd| {
        var run = prot.Run.init(self.env.a);
        defer run.deinit();
        run.cmd = try run.a.dupe(u8, cmd);
        for (self.args) |arg|
            try run.args.append(self.env.a, try run.a.dupe(u8, arg));

        try self.cio.send(run);
        if (self.env.log.level(1)) |w| {
            try w.print("Sent Run command\n", .{});
            try w.flush();
        }

        var output_indicator = Output.Indicator{};
        while (true) {
            var output = prot.Output.init(self.env.a);
            defer output.deinit();
            var done = prot.Done{};
            if (try self.cio.receive2(&output, &done)) {
                if (self.env.log.level(2)) |w| {
                    prot.printMessage(output, w, null);
                } else {
                    if (output.stdout) |str| {
                        try output_indicator.set(.stdout, self.env.stdout, self.env.stderr);
                        try self.env.stdout.writeAll(str);
                        try self.env.stdout.flush();
                    }
                    if (output.stderr) |str| {
                        try output_indicator.set(.stderr, self.env.stdout, self.env.stderr);
                        try self.env.stderr.writeAll(str);
                        try self.env.stderr.flush();
                    }
                }
            } else {
                if (self.env.log.level(1)) |w|
                    prot.printMessage(done, w, null);
                break;
            }
        }
        if (self.env.log.level(1)) |w| {
            try w.print("Received all output from Run command\n", .{});
            try w.flush();
        }

        // Collect
        if (collect) {
            const clt = prot.Collect{};
            if (self.env.log.level(1)) |w|
                prot.printMessage(clt, w, null);

            try self.cio.send(clt);

            try self.receiveFolderFromPeer(self.env.a, self.base, false);
        }
    }

    // Hangup
    try self.cio.send(bye);
}

pub fn runServer(self: *Self) !void {
    var bye = prot.Bye.init(self.env.a);
    defer bye.deinit();

    // Handshake
    {
        var hello: prot.Hello = undefined;
        if (try self.cio.receive2(&hello, &bye)) {
            if (self.env.log.level(1)) |w|
                prot.printMessage(hello, w, null);
            if (hello.version != prot.My.version) {
                try bye.setReason("Version mismatch: mine {} !=  peer {}", .{ prot.My.version, hello.version });
                try self.cio.send(bye);
                return Error.VersionMismatch;
            }
            try self.cio.send(prot.Hello{ .role = .Client, .status = .Ok });
        } else {
            if (self.env.log.level(1)) |w|
                prot.printMessage(bye, w, null);
            return Error.PeerGaveUp;
        }
    }

    // Sync
    var folder: []const u8 = &.{};
    defer self.env.a.free(folder);
    {
        var aa = std.heap.ArenaAllocator.init(self.env.a);
        defer aa.deinit();
        const a = aa.allocator();

        var sync = prot.Sync.init(a);

        if (!try self.cio.receive(&sync))
            return Error.ExpectedSync;
        if (self.env.log.level(1)) |w|
            prot.printMessage(sync, w, null);

        if (sync.reset_store) {
            try self.env.log.warning("Resetting the store\n", .{});
            try self.store.reset();
        }

        {
            const subdir = sync.subdir orelse return Error.SyncToRootNotSupportedYet;
            if (subdir.len == 0)
                return Error.EmptySubdir;
            if (std.fs.path.isAbsolute(subdir))
                return Error.OnlyRelativePathAllowed;

            folder = try std.fs.path.join(self.env.a, &[_][]const u8{ self.base, subdir });

            try self.receiveFolderFromPeer(a, folder, sync.reset_folder);
        }
    }

    // Run
    {
        var aa = std.heap.ArenaAllocator.init(self.env.a);
        defer aa.deinit();

        var run = prot.Run.init(aa.allocator());

        if (try self.cio.receive(&run)) {
            if (self.env.log.level(1)) |w|
                prot.printMessage(run, w, null);

            try self.doRun(run, folder);

            // Collect
            var collect = prot.Collect{};
            if (try self.cio.receive(&collect)) {
                if (self.env.log.level(1)) |w|
                    prot.printMessage(collect, w, null);

                try self.sendFolderToPeer(folder);
            }
        }
    }

    // Hangup
    if (try self.cio.receive(&bye)) {
        if (self.env.log.level(1)) |w|
            prot.printMessage(bye, w, null);
    }
}

fn doSync(self: *Self, folder: []const u8, reset: bool, tree: fs.Tree) !void {
    // Delete `folder` if necessary
    if (reset) {
        if (self.env.log.level(1)) |w| {
            try w.print("Deleting {s}\n", .{folder});
            try w.flush();
        }
        std.Io.Dir.cwd().deleteTree(self.env.io, folder) catch {};
    }

    // Helper to keep track of a subpath that is already open
    const D = struct {
        const D = @This();

        io: std.Io,
        folder: std.Io.Dir,
        path: []const u8 = &.{},
        dir: ?std.Io.Dir = null,

        fn deinit(d: *D) void {
            d.close();
        }
        fn set(d: *D, wanted_path: []const u8) !void {
            if (std.mem.eql(u8, wanted_path, d.path))
                return;
            d.close();
            d.path = wanted_path;
            if (d.path.len > 0)
                d.dir = try d.folder.createDirPathOpen(d.io, d.path, .{});
        }
        fn get(d: D) std.Io.Dir {
            return d.dir orelse d.folder;
        }
        fn close(d: *D) void {
            if (d.dir) |*dd| {
                dd.close(d.io);
                d.dir = null;
                d.path = &.{};
            }
        }
    };

    if (self.env.log.level(1)) |w| {
        const oper = if (rubr.fs.isDirectory(self.env.io, folder)) "Opening" else "Creating";
        try w.print("{s} folder {s}\n", .{ oper, folder });
    }
    var d = D{ .io = self.env.io, .folder = try std.Io.Dir.cwd().createDirPathOpen(self.env.io, folder, .{}) };
    defer d.deinit();

    if (self.env.log.level(1)) |w| {
        try w.print("Reconstructing the Tree...\n", .{});
        try w.flush();
    }
    var tmp = std.ArrayList(u8){};
    defer tmp.deinit(self.env.a);
    var extract_count: u64 = 0;
    for (tree.filestates.items, 0..) |file, count| {
        if (self.env.log.level(1)) |w| {
            if (@popCount(count) <= 1) {
                try w.print("\t{}: extracted {}\n", .{ count, extract_count });
                try w.flush();
            }
        }

        const checksum = file.checksum orelse return Error.ExpectedChecksum;
        const path = file.path orelse "";

        try d.set(path);

        var do_extract: bool = true;
        if (!reset) {
            if (d.get().openFile(self.env.io, file.name, .{ .mode = .read_only })) |f| {
                defer f.close(self.env.io);

                const stat = try f.stat(self.env.io);
                try tmp.resize(self.env.a, stat.size);
                var rbuf: [4096]u8 = undefined;
                var reader = f.reader(self.env.io, &rbuf);
                try reader.interface.readSliceAll(tmp.items);
                const cs = crypto.checksum(tmp.items);
                if (std.mem.eql(u8, &cs, &checksum))
                    do_extract = false;
            } else |_| {
                if (self.env.log.level(1)) |w|
                    try w.print("\tCould not find {s}\n", .{file.name});
            }
        }

        if (do_extract) {
            if (!try self.store.extractFile(checksum, d.get(), file.name, file.attributes)) {
                try self.env.log.err("Could not extract file '{s}'\n", .{file.name});
                return Error.CouldNotExtractFile;
            }
            extract_count += 1;
        }
    }
    if (self.env.log.level(1)) |w| {
        try w.print("done\n", .{});
        try w.flush();
    }
}

fn doRun(self: *Self, run: prot.Run, folder: []const u8) !void {
    var argv = std.ArrayList([]const u8){};
    defer argv.deinit(self.env.a);

    try argv.append(self.env.a, run.cmd);
    for (run.args.items) |arg|
        try argv.append(self.env.a, arg);

    // &todo: This might not work for Windows yet: https://github.com/ziglang/zig/issues/5190
    var folder_dir = try std.Io.Dir.cwd().createDirPathOpen(self.env.io, folder, .{});
    defer folder_dir.close(self.env.io);

    const options = std.process.SpawnOptions{
        .argv = argv.items,
        .cwd_dir = folder_dir,
        .stdout = .pipe,
        .stderr = .pipe,
    };

    var proc = try std.process.spawn(self.env.io, options);

    {
        // Reading data from stdout/stderr crossplatform nonblocking seems most easy using MT
        self.maybe_stdout = proc.stdout;
        self.maybe_stderr = proc.stderr;
        var thread_stdout = try std.Thread.spawn(.{}, processOutputStdout, .{self});
        defer thread_stdout.join();
        var thread_stderr = try std.Thread.spawn(.{}, processOutputStderr, .{self});
        defer thread_stderr.join();
    }

    const term = try proc.wait(self.env.io);
    if (self.env.log.level(1)) |w|
        try w.print("term: {}\n", .{term});

    var done = prot.Done{};
    switch (term) {
        .exited => |v| done.exit = v,
        .signal => |v| done.signal = @intFromEnum(v),
        .stopped => |v| done.stop = v,
        .unknown => |v| done.unknown = v,
    }
    try self.cio.send(done);
}

fn processOutputStdout(self: *Self) !void {
    try self.processOutput_(&self.maybe_stdout, .stdout);
}
fn processOutputStderr(self: *Self) !void {
    try self.processOutput_(&self.maybe_stderr, .stderr);
}
fn processOutput_(self: *Self, maybe_output: *?std.Io.File, kind: Output.Kind) !void {
    var buf: [1024]u8 = undefined;
    if (maybe_output.*) |output| {
        var b: [1024]u8 = undefined;
        var reader = output.reader(self.env.io, &b);
        var output_indicator = Output.Indicator{};
        while (true) {
            const n = try reader.interface.readSliceShort(&buf);
            if (n > 0) {
                if (self.env.log.level(1)) |w| {
                    try output_indicator.set(kind, w, w);
                    try w.print("{s}", .{buf[0..n]});
                    try w.flush();
                }

                var outp = prot.Output.init(self.env.a);
                defer outp.deinit();
                switch (kind) {
                    .stdout => outp.stdout = try outp.a.dupe(u8, buf[0..n]),
                    .stderr => outp.stderr = try outp.a.dupe(u8, buf[0..n]),
                }

                {
                    self.mutex.lock();
                    defer self.mutex.unlock();
                    try self.cio.send(outp);
                }
            }
            if (n < buf.len) {
                // End of file
                maybe_output.* = null;
                break;
            }
        }
    }
}

fn sendFolderToPeer(self: *Self, folder: []const u8) !void {
    // Collect all FileStates for this folder
    var tree = try fs.collectTree(self.env, folder);
    defer tree.deinit();

    // Send all FileStates
    {
        for (tree.filestates.items, 0..) |filestate, count| {
            if (self.env.log.level(1)) |w|
                prot.printMessage(filestate, w, count);

            try self.cio.send(filestate);
        }

        // Indicate we sent all FileStates
        const sentinel = prot.FileState.init(self.env.a);
        try self.cio.send(sentinel);

        if (self.env.log.level(1)) |w| {
            try w.print("Sent all {} FileStates\n", .{tree.filestates.items.len});
            try w.flush();
        }
    }

    // Read all the Missing data
    var missings = std.ArrayList(usize){};
    defer missings.deinit(self.env.a);
    for (0..std.math.maxInt(usize)) |count| {
        var missing = prot.Missing{};
        if (try self.cio.receive(&missing)) {
            if (self.env.log.level(1)) |w|
                prot.printMessage(missing, w, count);

            if (missing.id) |id| {
                try missings.append(self.env.a, id);
            } else {
                // Peer has all the data
                break;
            }
        }
    }
    if (self.env.log.level(1)) |w| {
        try w.print("Server misses {} files\n", .{missings.items.len});
        try w.flush();
    }

    // Send all the missing Content
    for (missings.items, 0..) |id, count| {
        var content = prot.Content{ .a = null, .id = id };

        content.str = try tree.getContent(id);

        if (self.env.log.level(1)) |w|
            prot.printMessage(content, w, count);

        try self.cio.send(content);
    }
    try self.cio.send(prot.Content{ .a = null });
    if (self.env.log.level(1)) |w| {
        try w.print("Sent all missing Content\n", .{});
        try w.flush();
    }
}

fn receiveFolderFromPeer(self: *Self, a: std.mem.Allocator, folder: []const u8, reset: bool) !void {
    var tree = fs.Tree{ .env = self.env };
    tree.env.a = a;
    defer tree.deinit();

    // Receive all the FileStates of the Tree we have to recreate into folder
    // We compute the missing data immediately
    var missings = std.ArrayList(u64){};
    defer missings.deinit(a);
    {
        while (true) {
            var filestate = prot.FileState.init(a);
            if (!try self.cio.receive(&filestate))
                return Error.ExpectedFileState;

            if (self.env.log.level(1)) |w|
                prot.printMessage(filestate, w, tree.filestates.items.len);

            const id = filestate.id orelse break;

            try tree.filestates.append(a, filestate);

            const checksum = filestate.checksum orelse return Error.ExpectedChecksum;
            if (!self.store.hasFile(checksum)) {
                // Indicate we do not have this file
                try missings.append(a, id);
            }
        }
        if (self.env.log.level(1)) |w| {
            try w.print("Received {} FileStates, I miss {}\n", .{ tree.filestates.items.len, missings.items.len });
            try w.flush();
        }
    }

    // Indicate the content we are Missing
    {
        for (missings.items) |id| {
            try self.cio.send(prot.Missing{ .id = id });
        }
        try self.cio.send(prot.Missing{ .id = null });
        if (self.env.log.level(1)) |w| {
            try w.print("Sent all Missings\n", .{});
            try w.flush();
        }
    }

    // Receive the missing Content
    {
        for (0..std.math.maxInt(usize)) |count| {
            var content = prot.Content{ .a = a };
            defer content.deinit();

            if (!try self.cio.receive(&content))
                return Error.ExpectedContent;

            if (self.env.log.level(1)) |w|
                prot.printMessage(content, w, count);

            if (content.id == null)
                break;

            const str = content.str orelse return Error.ExpectedString;
            try self.store.addFile(crypto.checksum(str), str);
        }
        if (self.env.log.level(1)) |w| {
            try w.print("Received all content\n", .{});
            try w.flush();
        }
    }

    // Recreate the folder
    try self.doSync(folder, reset, tree);
}

const Output = struct {
    const Kind = enum { stdout, stderr };
    const Indicator = struct {
        maybe_kind: ?Kind = null,

        fn set(self: *@This(), kind: Kind, outw: *std.Io.Writer, errw: *std.Io.Writer) !void {
            if (self.maybe_kind == kind)
                return;

            switch (kind) {
                .stdout => try outw.writeAll("\u{1f7e2}"),
                .stderr => try errw.writeAll("\u{1f534}"),
            }
            self.maybe_kind = kind;
        }
    };
};
