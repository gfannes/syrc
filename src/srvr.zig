// &todo: Rename into Sink

const std = @import("std");
const prot = @import("prot.zig");
const comm = @import("comm.zig");
const rubr = @import("rubr.zig");
const Env = rubr.Env;

pub const Error = error{
    ExpectedHello,
    ExpectedReplicate,
    ExpectedRun,
    ExpectedBye,
    EmptyBaseFolder,
    BaseAlreadySet,
    BaseNotSet,
    UnknownId,
    VersionMismatch,
    PeerGaveUp,
};

pub const Session = struct {
    const Self = @This();

    env: Env,
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

            var replicate = prot.Replicate.init(aa.allocator());

            if (try self.cio.receive(&replicate)) {
                prot.printMessage(replicate, self.env.log);
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
        if (replicate.base.len == 0)
            return Error.EmptyBaseFolder;

        if (self.env.log.level(1)) |w|
            try w.print("Deleting {s}, if present\n", .{replicate.base});
        std.fs.cwd().deleteTree(replicate.base) catch {};

        if (self.env.log.level(1)) |w|
            try w.print("Creating base {s}\n", .{replicate.base});
        const base = try std.fs.cwd().makeOpenPath(replicate.base, .{});

        // Store base dir for prot.Run
        if (self.base != null)
            return Error.BaseAlreadySet;
        self.base = base;

        for (replicate.files.items) |file| {
            _ = file;
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
