const std = @import("std");

pub const Store = struct {
    const Self = @This();
    pub const Key = [64]u8;
    const Subdir = [Key.len + 2]u8;

    a: std.mem.Allocator,
    dir: ?std.fs.Dir = null,

    pub fn init(a: std.mem.Allocator) Self {
        return Store{ .a = a };
    }
    pub fn deinit(self: *Self) void {
        self.close();
    }

    pub fn open(self: *Self, path: []const u8) !void {
        self.close();
        self.dir = try std.fs.cwd().makeOpenPath(path, .{});
    }
    pub fn close(self: *Self) void {
        if (self.dir) |*dir| {
            dir.close();
            self.dir = null;
        }
    }

    // https://cfengine.com/blog/2024/efficient-data-copying-on-modern-linux/
    // Use sendfile() or copy_file_range()
    pub fn extract(self: *Self, key: Key, filename: []const u8) !bool {
        if (self.dir) |dir| {
            const subdir = toSubdir(key);
            if (dir.openFile(subdir, .{})) |file| {
                defer file.close();
                return true;
            } else |_| {
                return false;
            }
        } else {
            return false;
        }
    }

    // Split Key into Subdir creating 2 layers of subdirs of 2 chars each, and the rest as the filename
    fn toSubdir(key: Key) Subdir {
        var subdir: Subdir = undefined;

        subdir[0] = key[0];
        subdir[1] = key[1];
        subdir[2] = std.fs.path.sep;

        subdir[3] = key[2];
        subdir[4] = key[3];
        subdir[5] = std.fs.path.sep;

        std.mem.copyForward(u8, subdir[6..], key[4..]);

        return subdir;
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

    try store.open(path);
    defer std.fs.cwd().deleteTree(path) catch {};

    try ut.expect(store.dir != null);
    {
        var dir = try std.fs.cwd().openDir(path, .{});
        dir.close();
    }
}
