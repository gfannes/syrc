// &todo: Rename into Source

const std = @import("std");
const prot = @import("prot.zig");
const comm = @import("comm.zig");
const tree = @import("tree.zig");
const rubr = @import("rubr.zig");
const Env = rubr.Env;

pub const Error = error{
    ExpectedHello,
    ExpectedReplicate,
    ExpectedRun,
    ExpectedBye,
    ExpectedStatusOk,
    EmptyBaseFolder,
    BaseAlreadySet,
    BaseNotSet,
    UnknownId,
    PeerGaveUp,
};

pub const Session = struct {
    const Self = @This();

    env: Env,
    base: []const u8,
    src_dir: std.fs.Dir,

    maybe_cmd: ?[]const u8 = null,
    args: []const []const u8 = &.{},
    cio: comm.Io = undefined,

    pub fn init(self: *Self, stream: std.Io.net.Stream) void {
        self.cio.init(self.env.io, stream);
    }
    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn setArgv(self: *Self, argv: []const []const u8) void {
        if (argv.len < 1)
            return;
        self.maybe_cmd = argv[0];
        self.args = argv[1..];
    }

    pub fn execute(self: *Self) !void {
        var bye = prot.Bye.init(self.env.a);
        defer bye.deinit();

        try self.cio.send(prot.Hello{ .role = .Client, .status = .Pending });

        {
            var hello: prot.Hello = undefined;
            if (try self.cio.receive2(&hello, &bye)) {
                prot.printMessage(hello, self.env.log);
                if (hello.status != .Ok) {
                    try bye.setReason("Expected status Ok, not {}", .{hello.status});
                    try self.cio.send(bye);
                    return Error.ExpectedStatusOk;
                }
            } else {
                prot.printMessage(bye, self.env.log);
                return Error.PeerGaveUp;
            }
        }

        {
            var replicate = prot.Replicate.init(self.env.a);
            defer replicate.deinit();
            replicate.base = try replicate.a.dupe(u8, self.base);
            replicate.files = try tree.collectFileStates(self.src_dir, self.env);

            try self.cio.send(replicate);
        }

        if (self.maybe_cmd) |cmd| {
            var run = prot.Run.init(self.env.a);
            defer run.deinit();
            run.cmd = try run.a.dupe(u8, cmd);
            for (self.args) |arg|
                try run.args.append(self.env.a, try run.a.dupe(u8, arg));

            try self.cio.send(run);
        }

        try self.cio.send(bye);
    }
};
