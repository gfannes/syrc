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

        if (self.env.log.level(1)) |w|
            try w.print("Waiting for connection...\n", .{});

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
                prot.printMessage(hello, self.env.log);
                if (hello.version != prot.My.version) {
                    try bye.setReason("Version mismatch: mine {} !=  peer {}", .{ prot.My.version, hello.version });
                    try self.cio.send(bye);
                    return Error.VersionMismatch;
                }
                try self.cio.send(prot.Hello{ .role = .Client, .status = .Ok });
            } else {
                prot.printMessage(bye, self.env.log);
                return Error.PeerGaveUp;
            }
        }

        // Sync
        {
            var aa = std.heap.ArenaAllocator.init(self.env.a);
            defer aa.deinit();
            const a = aa.allocator();

            var replicate = prot.Replicate.init(a);

            if (try self.cio.receive(&replicate)) {
                prot.printMessage(replicate, self.env.log);

                // Indicate the content that we still miss
                {
                    var missing = prot.Missing.init(a);
                    defer missing.deinit();

                    for (replicate.files.items, 0..) |file, ix0| {
                        const checksum = file.checksum orelse return Error.ExpectedChecksum;
                        if (!self.store.hasFile(checksum)) {
                            try missing.ixs.append(a, ix0);
                        }
                    }

                    try self.cio.send(missing);
                }

                // Place the missing content in the blob.Store
                {
                    var content = prot.Content.init(a, true);
                    defer content.deinit();

                    if (try self.cio.receive(&content)) {
                        prot.printMessage(content, self.env.log);

                        for (content.data.items) |str| {
                            try self.store.addFile(crypto.checksum(str), str);
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
                prot.printMessage(run, self.env.log);
                try self.doRun(run);
            }
        }

        // Hangup
        if (try self.cio.receive(&bye))
            prot.printMessage(bye, self.env.log);
    }

    fn doReplicate(self: *Self, replicate: prot.Replicate) !void {
        const base = replicate.base;

        if (base.len == 0)
            return Error.EmptyBaseFolder;
        if (std.fs.path.isAbsolute(base))
            return Error.OnlyRelativePathAllowed;
        if (rubr.fs.isDirectory(base)) {
            if (self.env.log.level(1)) |w|
                try w.print("Deleting {s}\n", .{base});
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

        var maybe_stdout = proc.stdout;
        var maybe_stderr = proc.stderr;
        while (maybe_stdout != null or maybe_stderr != null) {
            try processOutput(self.env.io, &maybe_stdout, .stdout);
            try processOutput(self.env.io, &maybe_stderr, .stderr);
        }

        // &todo: Provide exit code to Client
        const term = try proc.wait();
        std.debug.print("term: {}\n", .{term});
    }

    const OutputKind = enum { stdout, stderr };
    fn processOutput(io: std.Io, maybe_output: *?std.fs.File, kind: OutputKind) !void {
        var buf: [1024]u8 = undefined;
        if (maybe_output.*) |output| {
            var b: [1024]u8 = undefined;
            var reader = output.reader(io, &b);
            while (true) {
                const n = try reader.interface.readSliceShort(&buf);
                if (n > 0) {
                    // &todo: Provide output to Client
                    std.debug.print("output: {} {}=>({s})\n", .{ kind, n, buf[0..n] });
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
