const std = @import("std");
const crypto = @import("crypto.zig");

pub const Store = struct {
    const Self = @This();
    pub const Key = crypto.Checksum;
    const Subdir = [2 * Key.len + 2]u8;

    a: std.mem.Allocator,
    dir: ?std.fs.Dir = null,

    pub fn init(a: std.mem.Allocator) Self {
        return Store{ .a = a };
    }
    pub fn deinit(self: *Self) void {
        self.close();
    }

    // Creates `path` if it does not exist yet
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
        _ = filename;
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

        subdir[0..2].* = std.fmt.hex(key[0]);
        subdir[2] = std.fs.path.sep;

        subdir[3..5].* = std.fmt.hex(key[1]);
        subdir[5] = std.fs.path.sep;

        subdir[6..].* = std.fmt.bytesToHex(key[2..], .lower);

        return subdir;
    }
};

test "store" {
    const rubr = @import("rubr.zig");
    const ut = std.testing;
    const a = ut.allocator;

    var store = Store.init(a);
    defer store.deinit();

    const path = "tmp/store";

    // Verify that `path` does not exist
    try rubr.fs.deleteTree(path);
    try ut.expect(!rubr.fs.isDirectory(path));

    try store.open(path);

    try ut.expect(rubr.fs.isDirectory(path));

    defer std.fs.cwd().deleteTree(path) catch {};

    try ut.expect(store.dir != null);
    {
        var dir = try std.fs.cwd().openDir(path, .{});
        dir.close();
    }
}
