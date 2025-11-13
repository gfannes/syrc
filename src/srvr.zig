// &todo: Rename into Sink

const std = @import("std");
const prot = @import("prot.zig");
const comm = @import("comm.zig");
const blob = @import("blob.zig");
const crypto = @import("crypto.zig");
const rubr = @import("rubr.zig");
const Env = rubr.Env;

pub const Error = error{
    ExpectedHello,
    ExpectedReplicate,
    ExpectedRun,
    ExpectedBye,
    ExpectedListeningServer,
    ExpectedChecksum,
    ExpectedEqualLen,
    EmptyBaseFolder,
    BaseAlreadySet,
    BaseNotSet,
    UnknownId,
    VersionMismatch,
    PeerGaveUp,
    IXOutOfBound,
    OnlyRelativePathAllowed,
    CouldNotExtractFile,
};

pub const Server = struct {
    const Self = @This();

    env: Env,
    address: std.Io.net.IpAddress,
    store: *blob.Store,
    server: ?std.Io.net.Server = null,

    pub fn init(self: *Self) !void {
        if (self.env.log.level(1)) |w|
            try w.print("Creating server on {f}\n", .{self.address});
        self.server = try self.address.listen(self.env.io, .{ .reuse_address = true });
    }

    pub fn deinit(self: *Self) void {
        if (self.server) |*server|
            server.deinit(self.env.io);
    }

    pub fn processOne(self: *Self) !void {
        var server = self.server orelse return Error.ExpectedListeningServer;

        if (self.env.log.level(1)) |w| {
            try w.print("Waiting for connection...\n", .{});
            try w.flush();
        }

        var connection = try server.accept(self.env.io);
        defer connection.close(self.env.io);
        if (self.env.log.level(1)) |w|
            try w.print("Received connection {f}\n", .{connection.socket.address});

        var session = Session{
            .env = self.env,
            .store = self.store,
        };
        session.init(connection);
        defer session.deinit();

        try session.execute();
    }
};

pub const Session = struct {
    const Self = @This();

    env: Env,
    store: *blob.Store,
    cio: comm.Io = undefined,
    base: ?std.fs.Dir = null,

    maybe_stdout: ?std.fs.File = null,
    maybe_stderr: ?std.fs.File = null,
    mutex: std.Thread.Mutex = .{},

    pub fn init(self: *Self, stream: std.Io.net.Stream) void {
        self.cio.init(self.env.io, stream);
    }
    pub fn deinit(self: *Self) void {
        if (self.base) |*base|
            base.close();
    }

    pub fn execute(self: *Self) !void {
        var bye = prot.Bye.init(self.env.a);
        defer bye.deinit();

        // Handshake
        {
            var hello: prot.Hello = undefined;
            if (try self.cio.receive2(&hello, &bye)) {
                if (self.env.log.level(1)) |w|
                    prot.printMessage(hello, w);
                if (hello.version != prot.My.version) {
                    try bye.setReason("Version mismatch: mine {} !=  peer {}", .{ prot.My.version, hello.version });
                    try self.cio.send(bye);
                    return Error.VersionMismatch;
                }
                try self.cio.send(prot.Hello{ .role = .Client, .status = .Ok });
            } else {
                if (self.env.log.level(1)) |w|
                    prot.printMessage(bye, w);
                return Error.PeerGaveUp;
            }
        }

        // Sync
        {
            var aa = std.heap.ArenaAllocator.init(self.env.a);
            defer aa.deinit();
            const a = aa.allocator();

            var replicate = prot.Replicate.init(a);

            if (self.env.log.level(1)) |w| {
                try w.print("Receiving Replicate...\n", .{});
                try w.flush();
            }
            if (try self.cio.receive(&replicate)) {
                if (self.env.log.level(2)) |w|
                    prot.printMessage(replicate, w);

                // Indicate the content that we still miss
                {
                    if (self.env.log.level(1)) |w| {
                        try w.print("Computing Missing...\n", .{});
                        try w.flush();
                    }
                    var missing = prot.Missing.init(a);
                    defer missing.deinit();

                    for (replicate.files.items, 0..) |file, ix0| {
                        const checksum = file.checksum orelse return Error.ExpectedChecksum;
                        if (self.env.log.level(1)) |w| {
                            if (ix0 % 1000 == 0) {
                                try w.print("\t{}\t{s}\n", .{ ix0, std.fmt.bytesToHex(checksum, .lower) });
                                try w.flush();
                            }
                        }
                        if (!self.store.hasFile(checksum)) {
                            try missing.ixs.append(a, ix0);
                        }
                    }

                    if (self.env.log.level(1)) |w| {
                        try w.print("Sending Missing...\n", .{});
                        try w.flush();
                    }
                    try self.cio.send(missing);
                }

                // Place the missing content in the blob.Store
                {
                    var content = prot.Content.init(a, true);
                    defer content.deinit();

                    if (self.env.log.level(1)) |w| {
                        try w.print("Receiving Content...\n", .{});
                        try w.flush();
                    }
                    if (try self.cio.receive(&content)) {
                        if (self.env.log.level(1)) |w|
                            prot.printMessage(content, w);

                        if (self.env.log.level(1)) |w| {
                            try w.print("Storing data...\n", .{});
                            try w.flush();
                        }
                        for (content.data.items) |str| {
                            try self.store.addFile(crypto.checksum(str), str);
                        }
                        if (self.env.log.level(1)) |w| {
                            try w.print("done\n", .{});
                            try w.flush();
                        }
                    }
                }

                try self.doReplicate(replicate);
            }
        }

        // Run
        {
            var aa = std.heap.ArenaAllocator.init(self.env.a);
            defer aa.deinit();

            var run = prot.Run.init(aa.allocator());

            if (try self.cio.receive(&run)) {
                if (self.env.log.level(1)) |w|
                    prot.printMessage(run, w);
                try self.doRun(run);
            }
        }

        // Hangup
        if (try self.cio.receive(&bye)) {
            if (self.env.log.level(1)) |w|
                prot.printMessage(bye, w);
        }
    }

    fn doReplicate(self: *Self, replicate: prot.Replicate) !void {
        const base = replicate.base;

        if (base.len == 0)
            return Error.EmptyBaseFolder;
        if (std.fs.path.isAbsolute(base))
            return Error.OnlyRelativePathAllowed;
        if (rubr.fs.isDirectory(base)) {
            if (self.env.log.level(1)) |w| {
                try w.print("Deleting {s}\n", .{base});
                try w.flush();
            }
            std.fs.cwd().deleteTree(base) catch {};
        }
        if (self.env.log.level(1)) |w|
            try w.print("Creating base {s}\n", .{base});

        // Store base dir for prot.Run
        if (self.base != null)
            return Error.BaseAlreadySet;

        const base_dir = try std.fs.cwd().makeOpenPath(base, .{});
        self.base = base_dir;

        const D = struct {
            const D = @This();

            base: std.fs.Dir,
            path: []const u8 = &.{},
            dir: ?std.fs.Dir = null,

            fn deinit(d: *D) void {
                d.close();
            }
            fn set(d: *D, wanted_path: []const u8) !void {
                if (std.mem.eql(u8, wanted_path, d.path))
                    return;
                d.close();
                d.path = wanted_path;
                if (d.path.len > 0)
                    d.dir = try d.base.makeOpenPath(d.path, .{});
            }
            fn get(d: D) std.fs.Dir {
                return d.dir orelse d.base;
            }
            fn close(d: *D) void {
                if (d.dir) |*dd| {
                    dd.close();
                    d.dir = null;
                    d.path = &.{};
                }
            }
        };
        var d = D{ .base = base_dir };
        defer d.deinit();

        for (replicate.files.items) |file| {
            const checksum = file.checksum orelse return Error.ExpectedChecksum;

            try d.set(file.path orelse "");

            if (!try self.store.extractFile(checksum, d.get(), file.name, file.attributes)) {
                try self.env.log.err("Could not extract file '{s}'\n", .{file.name});
                return Error.CouldNotExtractFile;
            }
        }
    }

    fn doRun(self: *Self, run: prot.Run) !void {
        var argv = std.ArrayList([]const u8){};
        defer argv.deinit(self.env.a);

        try argv.append(self.env.a, run.cmd);
        for (run.args.items) |arg|
            try argv.append(self.env.a, arg);

        var proc = std.process.Child.init(argv.items, self.env.a);

        // &todo: This might not work for Windows yet: https://github.com/ziglang/zig/issues/5190
        const base = self.base orelse return Error.BaseNotSet;
        proc.cwd_dir = base;

        proc.stdout_behavior = .Pipe;
        proc.stderr_behavior = .Pipe;

        try proc.spawn();

        {
            // Reading data from stdout/stderr crossplatform nonblocking seems most easy using MT
            self.maybe_stdout = proc.stdout;
            self.maybe_stderr = proc.stderr;
            var thread_stdout = try std.Thread.spawn(.{}, processOutputStdout, .{self});
            defer thread_stdout.join();
            var thread_stderr = try std.Thread.spawn(.{}, processOutputStderr, .{self});
            defer thread_stderr.join();
        }

        const term = try proc.wait();
        if (self.env.log.level(1)) |w|
            try w.print("term: {}\n", .{term});

        var done = prot.Done{};
        switch (term) {
            .Exited => |v| done.exit = v,
            .Signal => |v| done.signal = v,
            .Stopped => |v| done.stop = v,
            .Unknown => |v| done.unknown = v,
        }
        try self.cio.send(done);
    }

    const OutputKind = enum { stdout, stderr };
    fn processOutputStdout(self: *Self) !void {
        try self.processOutput_(&self.maybe_stdout, .stdout);
    }
    fn processOutputStderr(self: *Self) !void {
        try self.processOutput_(&self.maybe_stderr, .stderr);
    }
    fn processOutput_(self: *Self, maybe_output: *?std.fs.File, kind: OutputKind) !void {
        var buf: [1024]u8 = undefined;
        if (maybe_output.*) |output| {
            var b: [1024]u8 = undefined;
            var reader = output.reader(self.env.io, &b);
            while (true) {
                const n = try reader.interface.readSliceShort(&buf);
                if (n > 0) {
                    if (self.env.log.level(1)) |w|
                        try w.print("output: {} {}=>({s})\n", .{ kind, n, buf[0..n] });

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
};
