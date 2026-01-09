const std = @import("std");
const builtin = @import("builtin");
const crypto = @import("crypto.zig");
const prot = @import("prot.zig");
const rubr = @import("rubr.zig");

pub const Error = error{
    ExpectedDir,
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

    env: rubr.Env,
    dir: ?std.Io.Dir = null,
    tmp: Buffer = .{},

    pub fn init(env: rubr.Env) Self {
        return Store{ .env = env };
    }
    pub fn deinit(self: *Self) void {
        self.close();
        self.tmp.deinit(self.env.a);
    }

    // Creates `path` if it does not exist yet
    pub fn open(self: *Self, path: []const u8) !void {
        self.close();
        self.dir = try std.Io.Dir.cwd().createDirPathOpen(self.env.io, path, .{});
    }
    pub fn close(self: *Self) void {
        if (self.dir) |*dir| {
            dir.close(self.env.io);
            self.dir = null;
        }
    }

    pub fn hasFile(self: *Self, key: Key) bool {
        if (self.dir) |dir| {
            const subpath = SubPath.init(key);
            if (dir.openFile(self.env.io, subpath.all(), .{ .mode = .read_only })) |file| {
                file.close(self.env.io);
                return true;
            } else |_| {}
        }
        return false;
    }

    pub fn addFile(self: *Self, key: Key, content: []const u8) !void {
        const dir = self.dir orelse return Error.ExpectedDir;

        const subpath = SubPath.init(key);

        var subdir = try dir.createDirPathOpen(self.env.io, subpath.dir(), .{});
        defer subdir.close(self.env.io);

        const file = try subdir.createFile(self.env.io, subpath.name(), .{});
        defer file.close(self.env.io);

        var buffer: [4096]u8 = undefined;
        var writer = file.writer(self.env.io, &buffer);
        try writer.interface.writeAll(content);
    }

    // &todo: set attributes as well
    // https://cfengine.com/blog/2024/efficient-data-copying-on-modern-linux/
    // Use sendfile() or copy_file_range()
    pub fn extractFile(self: *Self, key: Key, dir: std.Io.Dir, filename: []const u8, attributes: ?prot.FileState.Attributes) !bool {
        {
            const src_dir = self.dir orelse return Error.ExpectedDir;

            const subpath = SubPath.init(key);

            const file = src_dir.openFile(self.env.io, subpath.all(), .{ .mode = .read_only }) catch return false;
            defer file.close(self.env.io);

            const stat = try file.stat(self.env.io);
            try self.tmp.resize(self.env.a, stat.size);
            var rbuf: [4096]u8 = undefined;
            var reader = file.reader(self.env.io, &rbuf);
            try reader.interface.readSliceAll(self.tmp.items);
        }

        {
            const file = try dir.createFile(self.env.io, filename, .{});
            defer file.close(self.env.io);

            var wbuf: [4096]u8 = undefined;
            var writer = file.writer(self.env.io, &wbuf);
            try writer.interface.writeAll(self.tmp.items);

            if (attributes) |attr| {
                var permissions = std.Io.File.Permissions.default_file;
                permissions = permissions.setReadOnly(attr.read);
                // &todo support executable permission
                if (builtin.os.tag != .windows)
                    try file.setPermissions(self.env.io, permissions);
            }
        }

        return true;
    }

    pub fn reset(self: *Self) !void {
        const dir = self.dir orelse return Error.ExpectedDir;

        for (0..256) |i| {
            const byte: u8 = @intCast(i);
            const subdir = std.fmt.hex(byte);
            dir.deleteTree(self.env.io, &subdir) catch {};
        }
    }
};

test "blob.Store" {
    const ut = std.testing;
    const a = ut.allocator;
    const io = ut.io;

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

    var dst_dir = try std.Io.Dir.cwd().createDirPathOpen(io, "tmp/repro", .{});
    defer dst_dir.close(io);

    try ut.expect(try store.extractFile(key, dst_dir, "myfile.txt", null));
}
