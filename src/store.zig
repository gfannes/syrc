const std = @import("std");
const crypto = @import("crypto.zig");
const rubr = @import("rubr.zig");

pub const Error = error{
    ExpectedDir,
    ExpectedSameSize,
};

pub const Key = crypto.Checksum;

// Helper to convert Key into a two-level hex path
const SubPath = struct {
    const Self = @This();

    buf: [2 * rubr.util.arrayLenOf(Key) + 2]u8 = undefined,

    // Split Key into Subdir creating 2 layers of subdirs of 2 chars each, and the rest as the filename
    fn init(key: Key) SubPath {
        var res: SubPath = undefined;

        res.buf[0..2].* = std.fmt.hex(key[0]);
        res.buf[2] = std.fs.path.sep;

        res.buf[3..5].* = std.fmt.hex(key[1]);
        res.buf[5] = std.fs.path.sep;

        res.buf[6..].* = std.fmt.bytesToHex(key[2..], .lower);

        return res;
    }

    fn dir(self: *const Self) []const u8 {
        return self.buf[0..5];
    }
    fn name(self: *const Self) []const u8 {
        return self.buf[6..];
    }
    fn all(self: *const Self) []const u8 {
        return &self.buf;
    }
};

pub const Store = struct {
    const Self = @This();
    const Buffer = std.ArrayList(u8);

    a: std.mem.Allocator,
    dir: ?std.fs.Dir = null,
    tmp: Buffer = .{},

    pub fn init(a: std.mem.Allocator) Self {
        return Store{ .a = a };
    }
    pub fn deinit(self: *Self) void {
        self.close();
        self.tmp.deinit(self.a);
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

    pub fn hasFile(self: *Self, key: Key) bool {
        if (self.dir) |dir| {
            const subpath = SubPath.init(key);
            if (dir.openFile(subpath.all(), .{ .mode = .read_only })) |file| {
                file.close();
                return true;
            } else |_| {}
        }
        return false;
    }

    pub fn addFile(self: *Self, key: Key, content: []const u8) !void {
        const dir = self.dir orelse return Error.ExpectedDir;

        const subpath = SubPath.init(key);

        var subdir = try dir.makeOpenPath(subpath.dir(), .{});
        defer subdir.close();

        const file = try subdir.createFile(subpath.name(), .{});
        defer file.close();

        try file.writeAll(content);
    }

    // &todo: set attributes as well
    // https://cfengine.com/blog/2024/efficient-data-copying-on-modern-linux/
    // Use sendfile() or copy_file_range()
    pub fn extractFile(self: *Self, key: Key, filename: []const u8) !bool {
        {
            const dir = self.dir orelse return Error.ExpectedDir;

            const subpath = SubPath.init(key);

            const file = dir.openFile(subpath.all(), .{ .mode = .read_only }) catch return false;
            defer file.close();

            const stat = try file.stat();
            try self.tmp.resize(self.a, stat.size);
            const size = try file.read(self.tmp.items);
            if (size != stat.size)
                return Error.ExpectedSameSize;
        }

        {
            const file = if (std.fs.path.isAbsolute(filename))
                try std.fs.createFileAbsolute(filename, .{})
            else
                try std.fs.cwd().createFile(filename, .{});
            defer file.close();

            try file.writeAll(self.tmp.items);
        }

        return true;
    }
};

test "store" {
    const ut = std.testing;
    const a = ut.allocator;

    var store = Store.init(a);
    defer store.deinit();

    const path = "tmp/store";

    // Ensure `path` does not exist
    try rubr.fs.deleteTree(path);
    try ut.expect(!rubr.fs.isDirectory(path));

    try store.open(path);
    try ut.expect(rubr.fs.isDirectory(path));

    try ut.expect(store.dir != null);

    var key: Key = undefined;
    for (&key, 0..) |*v, ix0| {
        const ix: u8 = @intCast(ix0 + (ix0 << 4));
        v.* = ix;
    }

    try ut.expect(!store.hasFile(key));

    try store.addFile(key, "Hello Store");
    try ut.expect(store.hasFile(key));

    try ut.expect(try store.extractFile(key, "myfile.txt"));
}
