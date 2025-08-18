const std = @import("std");
const rubr = @import("rubr.zig");
const prot = @import("prot.zig");
const tree = @import("tree.zig");

pub const Session = struct {
    const Self = @This();
    const TreeWriter = rubr.comm.TreeWriter(std.net.Stream);

    a: std.mem.Allocator,
    stream: std.net.Stream,
    tw: TreeWriter,

    pub fn init(a: std.mem.Allocator, stream: std.net.Stream) Self {
        return Self{ .a = a, .stream = stream, .tw = TreeWriter{ .out = stream } };
    }
    pub fn deinit(self: *Self) void {
        _ = self;
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
            msg.base = try msg.a.dupe(u8, "tmp");
            msg.files = try tree.collectFileStates(std.fs.cwd(), self.a);

            try self.tw.writeComposite(msg, T.Id);
        }

        {
            const T = prot.Run;
            var msg = T.init(self.a);
            defer msg.deinit();
            msg.cmd = try msg.a.dupe(u8, "rake");
            try msg.args.append(try msg.a.dupe(u8, "ut"));

            try self.tw.writeComposite(msg, T.Id);
        }

        {
            const T = prot.Bye;
            try self.tw.writeComposite(T{}, T.Id);
        }
    }
};
