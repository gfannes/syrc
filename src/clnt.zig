const std = @import("std");
const rubr = @import("rubr.zig");
const prot = @import("prot.zig");
const tree = @import("tree.zig");

pub const Session = struct {
    const Self = @This();
    const TreeWriter = rubr.comm.TreeWriter(std.net.Stream);

    a: std.mem.Allocator,
    stream: std.net.Stream,
    base: []const u8,
    maybe_cmd: ?[]const u8 = null,
    args: []const []const u8 = &.{},
    tw: TreeWriter,

    pub fn init(a: std.mem.Allocator, stream: std.net.Stream, base: []const u8) Self {
        return Self{
            .a = a,
            .stream = stream,
            .base = base,
            .tw = TreeWriter{ .out = stream },
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

    pub fn run(self: *Self) !void {
        {
            const T = prot.Hello;
            try self.tw.writeComposite(T{ .role = T.Role.Client, .status = T.Status.Pending }, T.Id);
        }

        {
            const T = prot.Replicate;
            var msg = T.init(self.a);
            defer msg.deinit();
            msg.base = try msg.a.dupe(u8, self.base);
            msg.files = try tree.collectFileStates(std.fs.cwd(), self.a);

            try self.tw.writeComposite(msg, T.Id);
        }

        if (self.maybe_cmd) |cmd| {
            const T = prot.Run;
            var msg = T.init(self.a);
            defer msg.deinit();
            msg.cmd = try msg.a.dupe(u8, cmd);
            for (self.args) |arg|
                try msg.args.append(try msg.a.dupe(u8, arg));

            try self.tw.writeComposite(msg, T.Id);
        }

        {
            const T = prot.Bye;
            try self.tw.writeComposite(T{}, T.Id);
        }
    }
};
