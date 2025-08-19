const std = @import("std");
const prot = @import("prot.zig");
const comm = @import("comm.zig");
const tree = @import("tree.zig");
const rubr = @import("rubr.zig");

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

    a: std.mem.Allocator,
    log: *const rubr.log.Log,
    stream: std.net.Stream,
    base: []const u8,
    maybe_cmd: ?[]const u8 = null,
    args: []const []const u8 = &.{},
    io: comm.Io,

    pub fn init(a: std.mem.Allocator, log: *const rubr.log.Log, stream: std.net.Stream, base: []const u8) Self {
        return Self{
            .a = a,
            .log = log,
            .stream = stream,
            .base = base,
            .io = comm.Io.init(stream),
        };
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
        var bye = prot.Bye.init(self.a);
        defer bye.deinit();

        try self.io.send(prot.Hello{ .role = .Client, .status = .Pending });

        {
            var hello: prot.Hello = undefined;
            if (try self.io.receive2(&hello, &bye)) {
                prot.printMessage(hello, self.log);
                if (hello.status != .Ok) {
                    try bye.setReason("Expected status Ok, not {}", .{hello.status});
                    try self.io.send(bye);
                    return Error.ExpectedStatusOk;
                }
            } else {
                prot.printMessage(bye, self.log);
                return Error.PeerGaveUp;
            }
        }

        {
            var replicate = prot.Replicate.init(self.a);
            defer replicate.deinit();
            replicate.base = try replicate.a.dupe(u8, self.base);
            replicate.files = try tree.collectFileStates(std.fs.cwd(), self.a);

            try self.io.send(replicate);
        }

        if (self.maybe_cmd) |cmd| {
            var run = prot.Run.init(self.a);
            defer run.deinit();
            run.cmd = try run.a.dupe(u8, cmd);
            for (self.args) |arg|
                try run.args.append(try run.a.dupe(u8, arg));

            try self.io.send(run);
        }

        try self.io.send(bye);
    }
};
