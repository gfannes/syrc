const std = @import("std");

pub const Store = struct {
    const Self = @This();

    a: std.mem.Allocator,
    dir: ?std.fs.Dir = null,

    pub fn init(a: std.mem.Allocator) Self {
        return Store{ .a = a };
    }
    pub fn deinit(self: *Self) void {
        self.close();
    }

    pub fn create(self: *Self, path: []const u8) !void {
        self.close();
        self.dir = try std.fs.cwd().makeOpenPath(path, .{});
    }
    pub fn close(self: *Self) void {
        if (self.dir) |*dir| {
            dir.close();
            self.dir = null;
        }
    }
};

test "create" {
    const ut = std.testing;
    const a = ut.allocator;

    var store = Store.init(a);
    defer store.deinit();

    const path = "tmp/store";

    {
        var result_dir = std.fs.cwd().openDir(path, .{});
        defer if (result_dir) |*dir| {
            dir.close();
        } else |_| {};
        try ut.expectError(error.FileNotFound, result_dir);
    }

    try store.create(path);
    defer std.fs.cwd().deleteTree(path) catch {};

    try ut.expect(store.dir != null);
    {
        var dir = try std.fs.cwd().openDir(path, .{});
        dir.close();
    }
}
