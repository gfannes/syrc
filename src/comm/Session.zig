const std = @import("std");
const builtin = @import("builtin");

const prot = @import("../prot.zig");
const fs = @import("../fs.zig");
const blob = @import("../blob.zig");
const crypto = @import("../crypto.zig");
const dto = @import("../dto.zig");
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

name: []const u8,
suffix: ?[]const u8 = null,

stream: ?std.Io.net.Stream = null,
cio: Io = undefined,
maybe_cmd: ?[]const u8 = null,
args: []const []const u8 = &.{},

maybe_stdout: ?std.Io.File = null,
maybe_stderr: ?std.Io.File = null,
mutex: std.Io.Mutex = .init,

pub fn init(self: *Self, stream: std.Io.net.Stream) !void {
    self.stream = stream;
    self.cio = Io{ .env = self.env };
    self.cio.init(stream);

    if (builtin.os.tag != .windows) {
        const sigaction = std.posix.Sigaction{
            .handler = .{ .handler = onSigInt },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        std.posix.sigaction(std.posix.SIG.INT, &sigaction, null);
    }
}

pub fn deinit(self: *Self) void {
    if (builtin.os.tag != .windows)
        std.posix.sigaction(std.posix.SIG.INT, null, null);

    if (self.stream) |*stream|
        stream.close(self.env.io);
}

pub fn runClient(self: *Self, reset_folder: bool, cleanup_folder: bool, reset_store: bool, collect: bool, defines: []dto.Define) !void {
    var bye = prot.Bye.init(self.env.a);
    defer bye.deinit();

    // Handshake
    {
        var aa = std.heap.ArenaAllocator.init(self.env.a);
        defer aa.deinit();
        const a = aa.allocator();

        try self.cio.send(prot.Hello{ .a = a, .role = .Client, .status = .Pending, .name = self.name, .suffix = self.suffix });

        var hello: prot.Hello = .{ .a = a };
        if (try self.cio.receive2(&hello, &bye)) {
            if (self.env.log.level(2)) |w|
                prot.printMessage(hello, w, null);
            if (hello.status != .Ok) {
                try bye.setReason("Expected status Ok, not {}", .{hello.status});
                try self.cio.send(bye);
                return error.ExpectedStatusOk;
            }
        } else {
            if (self.env.log.level(2)) |w|
                prot.printMessage(bye, w, null);
            return error.PeerGaveUp;
        }
    }

    // Sync
    {
        var sync: prot.Sync = .{};

        sync.reset_folder = reset_folder;
        sync.cleanup_folder = cleanup_folder;
        sync.reset_store = reset_store;
        if (self.env.log.level(2)) |w|
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
        for (defines) |define| {
            var copy: dto.Define = .{ .key = try run.a.dupe(u8, define.key) };
            if (define.value) |value|
                copy.value = try run.a.dupe(u8, value);
            try run.defines.append(self.env.a, copy);
        }

        try self.cio.send(run);
        if (self.env.log.level(1)) |w|
            try rubr.flush.print(w, "Sent Run command\n", .{});

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
                if (self.env.log.level(2)) |w|
                    prot.printMessage(done, w, null);
                break;
            }
        }
        if (self.env.log.level(1)) |w|
            try rubr.flush.print(w, "Received all output from Run command\n", .{});

        // Collect
        if (collect) {
            const clt = prot.Collect{};
            if (self.env.log.level(2)) |w|
                prot.printMessage(clt, w, null);

            try self.cio.send(clt);

            try self.receiveFolderFromPeer(self.env.a, self.base, false);
        }
    }

    // Hangup
    try self.cio.send(bye);
}

pub fn runServer(self: *Self) !void {
    var arena = std.heap.ArenaAllocator.init(self.env.a);
    defer arena.deinit();
    const aa = arena.allocator();

    var bye = prot.Bye.init(aa);

    // Handshake
    var hello: prot.Hello = .{ .a = aa };
    {
        if (try self.cio.receive2(&hello, &bye)) {
            if (self.env.log.level(2)) |w|
                prot.printMessage(hello, w, null);
            if (hello.version != prot.My.version) {
                try bye.setReason("Version mismatch: mine {} !=  peer {}", .{ prot.My.version, hello.version });
                try self.cio.send(bye);
                return error.VersionMismatch;
            }
            try self.cio.send(prot.Hello{ .a = aa, .role = .Client, .status = .Ok, .name = self.name, .suffix = self.suffix });
        } else {
            if (self.env.log.level(2)) |w|
                prot.printMessage(bye, w, null);
            return error.PeerGaveUp;
        }
    }

    // Sync
    var folder: []const u8 = &.{};
    {
        var sync: prot.Sync = .{};

        if (!try self.cio.receive(&sync))
            return error.ExpectedSync;
        if (self.env.log.level(2)) |w|
            prot.printMessage(sync, w, null);

        if (sync.reset_store) {
            try self.env.log.warning("Resetting the store\n", .{});
            try self.store.reset();
        }

        {
            var parts = [_][]const u8{ "syrc", hello.name, &.{} };
            var slice: [][]const u8 = &parts;
            if (hello.suffix) |suffix| {
                slice[2] = suffix;
            } else {
                slice.len = 2;
            }
            const name = try std.mem.join(aa, "-", slice);
            folder = try std.fs.path.join(aa, &[_][]const u8{ self.base, name });

            try self.receiveFolderFromPeer(aa, folder, sync.reset_folder);
        }
    }

    // Run
    {
        var run = prot.Run.init(aa);

        if (try self.cio.receive(&run)) {
            if (self.env.log.level(2)) |w|
                prot.printMessage(run, w, null);

            try self.doRun(run, folder);

            // Collect
            var collect = prot.Collect{};
            if (try self.cio.receive(&collect)) {
                if (self.env.log.level(2)) |w|
                    prot.printMessage(collect, w, null);

                try self.sendFolderToPeer(folder);
            }
        }
    }

    // Hangup
    if (try self.cio.receive(&bye)) {
        if (self.env.log.level(2)) |w|
            prot.printMessage(bye, w, null);
    }
}

fn doSync(self: *Self, folder: []const u8, reset: bool, tree: fs.Tree) !void {
    // Delete `folder` if necessary
    if (reset) {
        if (self.env.log.level(1)) |w|
            try rubr.flush.print(w, "Deleting {s}\n", .{folder});
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

    if (self.env.log.level(1)) |w|
        try rubr.flush.print(w, "Reconstructing the Tree...\n", .{});
    var tmp = std.ArrayList(u8).empty;
    defer tmp.deinit(self.env.a);
    var extract_count: u64 = 0;
    for (tree.filestates.items, 0..) |file, count| {
        if (self.env.log.level(1)) |w| {
            if (@popCount(count) <= 1)
                try rubr.flush.print(w, "\t{}: extracted {}\n", .{ count, extract_count });
        }

        const checksum = file.checksum orelse return error.ExpectedChecksum;
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

                do_extract = false;
                if (!std.mem.eql(u8, &cs, &checksum)) {
                    do_extract = true;
                }
                if (file.attributes) |attr| {
                    // We keep only the 3x3 lsbits and compare those
                    const attr_perm: u9 = @truncate(@intFromEnum(attr.permissions()));
                    const stat_perm: u9 = @truncate(@intFromEnum(stat.permissions));
                    if (attr_perm != stat_perm) {
                        // &todo: iso forcing a full extract when only the permissions need an update
                        // it would be faster to simply update the permission itself. Then again, not
                        // many files are expected to be already present with the correct state but
                        // wrong permissions.
                        do_extract = true;
                    }
                }
            } else |_| {
                if (self.env.log.level(1)) |w|
                    try w.print("\tCould not find {s}\n", .{file.name});
            }
        }

        if (do_extract) {
            if (!try self.store.extractFile(checksum, d.get(), file.name, file.attributes)) {
                try self.env.log.err("Could not extract file '{s}'\n", .{file.name});
                return error.CouldNotExtractFile;
            }
            extract_count += 1;
        }
    }
    if (self.env.log.level(1)) |w|
        try rubr.flush.print(w, "done\n", .{});
}

fn doRun(self: *Self, run: prot.Run, folder: []const u8) !void {
    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(self.env.a);

    try argv.append(self.env.a, run.cmd);
    for (run.args.items) |arg|
        try argv.append(self.env.a, arg);

    // &todo: This might not work for Windows yet: https://github.com/ziglang/zig/issues/5190
    var folder_dir = try std.Io.Dir.cwd().createDirPathOpen(self.env.io, folder, .{});
    defer folder_dir.close(self.env.io);

    var environ_map = try self.env.envmap.clone(self.env.a);
    defer environ_map.deinit();
    for (run.defines.items) |define| {
        if (define.value) |value| {
            std.debug.print("Adding define {s}={s}\n", .{ define.key, value });
            try environ_map.put(define.key, value);
        } else {
            std.debug.print("Removing define {s}\n", .{define.key});
            _ = environ_map.swapRemove(define.key);
        }
    }

    const options = std.process.SpawnOptions{
        .argv = argv.items,
        .cwd = .{ .dir = folder_dir },
        .stdout = .pipe,
        .stderr = .pipe,
        .environ_map = &environ_map,
    };

    var done = prot.Done{};
    var err_proc = std.process.spawn(self.env.io, options);
    if (err_proc) |*proc| {
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

        switch (term) {
            .exited => |v| done.exit = v,
            .signal => |v| done.signal = @intFromEnum(v),
            .stopped => |v| done.stop = @intFromEnum(v),
            .unknown => |v| done.unknown = v,
        }
    } else |err| {
        try self.env.log.err("Could not spawn process: {}\n", .{err});
        done.failure = switch (err) {
            error.FileNotFound => .FileNotFound,
            error.AccessDenied => .AccessDenied,
            else => .Unknown,
        };
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
    if (maybe_output.*) |output| {
        var rbuf: [1024]u8 = undefined;
        var reader = output.reader(self.env.io, &rbuf);

        var output_indicator = Output.Indicator{};
        while (reader.interface.peekGreedy(1)) |str| {
            defer reader.interface.tossBuffered();

            if (self.env.log.level(1)) |w| {
                try output_indicator.set(kind, w, w);
                try rubr.flush.print(w, "{s}", .{str});
            }

            var outp = prot.Output.init(self.env.a);
            defer outp.deinit();
            switch (kind) {
                .stdout => outp.stdout = try outp.a.dupe(u8, str),
                .stderr => outp.stderr = try outp.a.dupe(u8, str),
            }

            {
                try self.mutex.lock(self.env.io);
                defer self.mutex.unlock(self.env.io);
                try self.cio.send(outp);
            }
        } else |err| {
            // End of file
            maybe_output.* = null;
            if (err != error.EndOfStream)
                return err;
        }
    }
}

fn sendFolderToPeer(self: *Self, folder: []const u8) !void {
    // Collect all FileStates for this folder
    var tree = try fs.collectTree(self.env, folder);
    defer tree.deinit();

    // Send all FileStates
    {
        if (self.env.log.level(1)) |w|
            try rubr.flush.print(w, "Sending {} filestates ... ", .{tree.filestates.items.len});
        for (tree.filestates.items, 0..) |filestate, count| {
            if (self.env.log.level(2)) |w|
                prot.printMessage(filestate, w, count);

            try self.cio.send(filestate);
        }

        // Indicate we sent all FileStates
        const sentinel = prot.FileState.init(self.env.a);
        try self.cio.send(sentinel);

        if (self.env.log.level(1)) |w|
            try rubr.flush.print(w, "OK\n", .{});
    }

    // Read all the Missing data
    var missings = std.ArrayList(usize).empty;
    defer missings.deinit(self.env.a);
    for (0..std.math.maxInt(usize)) |count| {
        var missing = prot.Missing{};
        if (try self.cio.receive(&missing)) {
            if (self.env.log.level(2)) |w|
                prot.printMessage(missing, w, count);

            if (missing.id) |id| {
                try missings.append(self.env.a, id);
            } else {
                // Peer has all the data
                break;
            }
        }
    }

    if (self.env.log.level(1)) |w|
        try rubr.flush.print(w, "Sending {} missing files ... ", .{missings.items.len});

    // Send all the missing Content
    for (missings.items, 0..) |id, count| {
        var content = prot.Content{ .a = null, .id = id };

        content.str = try tree.getContent(id);

        if (self.env.log.level(2)) |w|
            prot.printMessage(content, w, count);

        try self.cio.send(content);
    }
    try self.cio.send(prot.Content{ .a = null });

    if (self.env.log.level(1)) |w|
        try rubr.flush.print(w, "OK\n", .{});
}

fn receiveFolderFromPeer(self: *Self, a: std.mem.Allocator, folder: []const u8, reset: bool) !void {
    var tree = fs.Tree{ .env = self.env };
    tree.env.a = a;
    defer tree.deinit();

    // Receive all the FileStates of the Tree we have to recreate into folder
    // We compute the missing data immediately
    var missings = std.ArrayList(u64).empty;
    defer missings.deinit(a);
    {
        while (true) {
            var filestate = prot.FileState.init(a);
            if (!try self.cio.receive(&filestate))
                return error.ExpectedFileState;

            if (self.env.log.level(2)) |w|
                prot.printMessage(filestate, w, tree.filestates.items.len);

            const id = filestate.id orelse break;

            try tree.filestates.append(a, filestate);

            const checksum = filestate.checksum orelse return error.ExpectedChecksum;
            if (!self.store.hasFile(checksum)) {
                // Indicate we do not have this file
                try missings.append(a, id);
            }
        }
        if (self.env.log.level(1)) |w|
            try rubr.flush.print(w, "Received {} FileStates, I miss {}\n", .{ tree.filestates.items.len, missings.items.len });
    }

    // Indicate the content we are Missing
    {
        for (missings.items) |id| {
            try self.cio.send(prot.Missing{ .id = id });
        }
        try self.cio.send(prot.Missing{ .id = null });
        if (self.env.log.level(1)) |w|
            try rubr.flush.print(w, "Sent all Missings\n", .{});
    }

    // Receive the missing Content
    {
        for (0..std.math.maxInt(usize)) |count| {
            var content = prot.Content{ .a = a };
            defer content.deinit();

            if (!try self.cio.receive(&content))
                return error.ExpectedContent;

            if (self.env.log.level(2)) |w|
                prot.printMessage(content, w, count);

            if (content.id == null)
                break;

            const str = content.str orelse return error.ExpectedString;
            try self.store.addFile(crypto.checksum(str), str);
        }
        if (self.env.log.level(1)) |w|
            try rubr.flush.print(w, "Received all content\n", .{});
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
                .stdout => try outw.writeAll("\u{1f7e3}"), // Purple dot
                .stderr => try errw.writeAll("\u{1f7e0}"), // Orange dot
            }
            self.maybe_kind = kind;
        }
    };
};

var signal_int_count: u32 = 0;
fn onSigInt(_: std.posix.SIG) callconv(.c) void {
    signal_int_count += 1;
    std.debug.print("Caught interrupt signal (count: {})\n", .{signal_int_count});
    if (signal_int_count > 4) {
        std.process.fatal("Too many interrupt signals received, aborting...", .{});
    }
}
