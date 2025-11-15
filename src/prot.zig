const std = @import("std");
const tree = @import("tree.zig");
const crypto = @import("crypto.zig");
const rubr = @import("rubr.zig");

pub const Error = error{
    ExpectedString,
    ExpectedVersion,
    ExpectedRole,
    ExpectedStatus,
    ExpectedFileState,
    ExpectedIX,
    ExpectedCmd,
    ExpectedArg,
    ExpectedFd,
    ExpectedRc,
    ExpectedCount,
    ReasonAlreadySet,
    NoAllocatorSet,
    WrongChecksumSize,
};

pub const My = struct {
    pub const version = 1;
};

pub const Hello = struct {
    const Self = @This();
    pub const Id = 2;
    pub const Role = enum { Client, Server, Broker };
    pub const Status = enum { Ok, Pending, Fail };

    version: u32 = My.version,
    role: Role,
    status: Status,

    pub fn write(self: Self, parent: *rubr.naft.Node) void {
        var node = parent.node("prot.Hello");
        defer node.deinit();
        node.attr("version", self.version);
        node.attr("role", self.role);
        node.attr("status", self.status);
    }
    pub fn writeComposite(self: Self, tw: anytype) !void {
        try tw.writeLeaf(self.version, 3);
        try tw.writeLeaf(@intFromEnum(self.role), 3);
        try tw.writeLeaf(@intFromEnum(self.status), 3);
    }
    pub fn readComposite(self: *Self, tr: anytype) !void {
        if (!try tr.readLeaf(&self.version, 3, {}))
            return Error.ExpectedVersion;

        var u: u32 = undefined;

        if (!try tr.readLeaf(&u, 3, {}))
            return Error.ExpectedRole;
        self.role = @enumFromInt(u);

        if (!try tr.readLeaf(&u, 3, {}))
            return Error.ExpectedStatus;
        self.status = @enumFromInt(u);
    }
};

pub const Sync = struct {
    const Self = @This();
    pub const Id = 4;

    a: std.mem.Allocator,
    subdir: ?[]const u8 = null,
    reset: bool = false,
    cleanup: bool = false,

    pub fn init(a: std.mem.Allocator) Self {
        return Self{ .a = a };
    }
    pub fn deinit(self: *Self) void {
        if (self.subdir) |subdir|
            self.a.free(subdir);
    }

    pub fn write(self: Self, parent: *rubr.naft.Node) void {
        var node = parent.node("prot.Sync");
        defer node.deinit();
        if (self.subdir) |subdir|
            node.attr("base", subdir);
        node.attr("reset", self.reset);
        node.attr("cleanup", self.cleanup);
    }

    pub fn writeComposite(self: Self, tw: anytype) !void {
        if (self.subdir) |subdir|
            try tw.writeLeaf(subdir, 3);
        try tw.writeLeaf(self.reset, 5);
        try tw.writeLeaf(self.cleanup, 7);
    }
    pub fn readComposite(self: *Self, tr: anytype) !void {
        var subdir: []const u8 = &.{};
        if (try tr.readLeaf(&subdir, 3, self.a))
            self.subdir = subdir;

        if (!try tr.readLeaf(&self.reset, 5, {}))
            return Error.ExpectedString;

        if (!try tr.readLeaf(&self.cleanup, 7, {}))
            return Error.ExpectedString;
    }
};

pub const FileState = struct {
    const Self = @This();
    pub const Id = 6;
    pub const Attributes = struct {
        read: bool = true,
        write: bool = false,
        execute: bool = false,
    };
    pub const Timestamp = u32;

    a: std.mem.Allocator,
    id: ?u64 = null,
    path: ?[]const u8 = null,
    name: []const u8 = &.{},
    content: ?[]const u8 = null,
    checksum: ?crypto.Checksum = null,
    attributes: ?Attributes = null,
    timestamp: ?Timestamp = null,

    pub fn init(a: std.mem.Allocator) Self {
        return Self{ .a = a };
    }
    pub fn deinit(self: *Self) void {
        if (self.path) |path|
            self.a.free(path);
        if (self.content) |content|
            self.a.free(content);
        self.a.free(self.name);
    }

    pub fn filename(self: Self, a: std.mem.Allocator) ![]const u8 {
        if (self.path) |path| {
            const parts = [_][]const u8{ path, "/", self.name };
            return std.mem.concat(a, u8, &parts);
        } else {
            return a.dupe(u8, self.name);
        }
    }

    pub fn writeComposite(self: Self, tw: anytype) !void {
        if (self.id) |id|
            try tw.writeLeaf(id, 3);
        if (self.path) |path|
            try tw.writeLeaf(path, 5);
        if (self.name.len > 0)
            try tw.writeLeaf(self.name, 7);

        if (self.attributes) |attributes| {
            var flags: u3 = 0;
            flags <<= 1;
            flags += if (attributes.read) 1 else 0;
            flags <<= 1;
            flags += if (attributes.write) 1 else 0;
            flags <<= 1;
            flags += if (attributes.execute) 1 else 0;
            try tw.writeLeaf(flags, 9);
        }

        if (self.timestamp) |timestamp|
            try tw.writeLeaf(timestamp, 11);

        if (self.checksum) |cs|
            try tw.writeLeaf(&cs, 13);
    }
    pub fn readComposite(self: *Self, tr: anytype) !void {
        {
            var id: u64 = undefined;
            self.id = if (try tr.readLeaf(&id, 3, {}))
                id
            else
                null;
        }

        {
            var path: []const u8 = &.{};
            self.path = if (try tr.readLeaf(&path, 5, self.a))
                path
            else
                null;
        }

        if (!try tr.readLeaf(&self.name, 7, self.a))
            self.name = &.{};

        {
            var flags: u3 = undefined;
            self.attributes = if (try tr.readLeaf(&flags, 9, {}))
                .{
                    .read = flags & (1 << 2) != 0,
                    .write = flags & (1 << 1) != 0,
                    .execute = flags & (1 << 0) != 0,
                }
            else
                null;
        }

        {
            var timestamp: Timestamp = undefined;
            self.timestamp = if (try tr.readLeaf(&timestamp, 11, {}))
                timestamp
            else
                null;
        }

        {
            var buf: crypto.Checksum = undefined;
            var fba = std.heap.FixedBufferAllocator.init(&buf);
            var checksum: []const u8 = &.{};
            if (try tr.readLeaf(&checksum, 13, fba.allocator())) {
                if (checksum.len != buf.len)
                    return Error.WrongChecksumSize;
                self.checksum = buf;
            } else {
                self.checksum = null;
            }
        }
    }

    pub fn write(self: Self, parent: *rubr.naft.Node) void {
        var node = parent.node("tree.FileState");
        defer node.deinit();
        if (self.id) |id|
            node.attr("id", id);
        if (self.path) |path|
            node.attr("path", path);
        if (self.name.len > 0)
            node.attr("name", self.name);
        if (self.content) |content|
            node.attr("content_size", content.len);
        if (self.attributes) |attributes| {
            var attr: [3]u8 = .{ '-', '-', '-' };
            if (attributes.read)
                attr[0] = 'r';
            if (attributes.write)
                attr[1] = 'w';
            if (attributes.execute)
                attr[2] = 'x';
            node.attr("attr", &attr);
        }
        if (self.checksum) |checksum| {
            var buffer: [2 * rubr.util.arrayLenOf(crypto.Checksum)]u8 = undefined;
            for (checksum, 0..) |byte, ix0| {
                const ix = 2 * ix0;
                _ = std.fmt.bufPrint(buffer[ix .. ix + 2], "{x:0>2}", .{byte}) catch unreachable;
            }
            node.attr("checksum", &buffer);
        }
    }
};

pub const Missing = struct {
    const Self = @This();
    const IXs = std.ArrayList(usize);
    pub const Id = 8;

    id: ?u64 = null,

    pub fn write(self: Self, parent: *rubr.naft.Node) void {
        var node = parent.node("prot.Missing");
        defer node.deinit();

        if (self.id) |id|
            node.attr("id", id);
    }

    pub fn writeComposite(self: Self, tw: anytype) !void {
        if (self.id) |id|
            try tw.writeLeaf(id, 3);
    }
    pub fn readComposite(self: *Self, tr: anytype) !void {
        var id: u64 = undefined;
        self.id = if (try tr.readLeaf(&id, 3, {}))
            id
        else
            null;
    }
};

pub const Content = struct {
    const Self = @This();
    pub const Id = 10;

    // If set, `a` will be used to free `str`.
    a: ?std.mem.Allocator,
    id: ?u64 = null,
    str: ?[]const u8 = null,

    pub fn deinit(self: *Self) void {
        if (self.str) |str|
            if (self.a) |a|
                a.free(str);
    }

    pub fn write(self: Self, parent: *rubr.naft.Node) void {
        var node = parent.node("prot.Content");
        defer node.deinit();
        if (self.id) |id|
            node.attr("id", id);
        if (self.str) |str|
            node.attr("len", str.len);
    }

    pub fn writeComposite(self: Self, tw: anytype) !void {
        if (self.id) |id|
            try tw.writeLeaf(id, 3);
        if (self.str) |str|
            try tw.writeLeaf(str, 5);
    }
    pub fn readComposite(self: *Self, tr: anytype) !void {
        var id: u64 = undefined;
        self.id = if (try tr.readLeaf(&id, 3, {}))
            id
        else
            null;

        const a = self.a orelse return Error.NoAllocatorSet;
        var str: []const u8 = &.{};
        if (try tr.readLeaf(&str, 5, a))
            self.str = str;
    }
};

pub const Run = struct {
    const Self = @This();
    pub const Id = 12;
    pub const Args = std.ArrayList([]const u8);

    a: std.mem.Allocator,
    cmd: []const u8 = &.{},
    args: Args = .{},

    pub fn init(a: std.mem.Allocator) Self {
        return Self{ .a = a };
    }
    pub fn deinit(self: *Self) void {
        self.a.free(self.cmd);
        for (self.args.items) |arg|
            self.a.free(arg);
        self.args.deinit(self.a);
    }

    pub fn write(self: Self, parent: *rubr.naft.Node) void {
        var node = parent.node("prot.Run");
        defer node.deinit();
        node.attr("cmd", self.cmd);
        for (self.args.items) |arg|
            node.attr("arg", arg);
    }

    pub fn writeComposite(self: Self, tw: anytype) !void {
        try tw.writeLeaf(self.cmd, 3);
        try tw.writeLeaf(self.args.items.len, 5);
        for (self.args.items) |arg|
            try tw.writeLeaf(arg, 7);
    }
    pub fn readComposite(self: *Self, tr: anytype) !void {
        if (!try tr.readLeaf(&self.cmd, 3, self.a))
            return Error.ExpectedCmd;

        var count: usize = undefined;
        if (!try tr.readLeaf(&count, 5, {}))
            return Error.ExpectedCount;

        try self.args.resize(self.a, count);
        for (self.args.items) |*arg| {
            if (!try tr.readLeaf(arg, 7, self.a))
                return Error.ExpectedArg;
        }
    }
};

pub const Output = struct {
    const Self = @This();
    pub const Id = 14;

    a: std.mem.Allocator,
    stdout: ?[]const u8 = null,
    stderr: ?[]const u8 = null,

    pub fn init(a: std.mem.Allocator) Self {
        return Self{ .a = a };
    }
    pub fn deinit(self: *Self) void {
        if (self.stdout) |str|
            self.a.free(str);
        if (self.stderr) |str|
            self.a.free(str);
    }

    pub fn write(self: Self, parent: *rubr.naft.Node) void {
        var node = parent.node("prot.Output");
        defer node.deinit();
        if (self.stdout) |str|
            node.attr("stdout", str);
        if (self.stderr) |str|
            node.attr("stderr", str);
    }

    pub fn writeComposite(self: Self, tw: anytype) !void {
        if (self.stdout) |str|
            try tw.writeLeaf(str, 3);
        if (self.stderr) |str|
            try tw.writeLeaf(str, 5);
    }
    pub fn readComposite(self: *Self, tr: anytype) !void {
        var str: []const u8 = undefined;
        if (try tr.readLeaf(&str, 3, self.a))
            self.stdout = str;
        if (try tr.readLeaf(&str, 5, self.a))
            self.stderr = str;
    }
};

pub const Done = struct {
    const Self = @This();
    pub const Id = 16;

    exit: ?u32 = null,
    signal: ?u32 = null,
    stop: ?u32 = null,
    unknown: ?u32 = null,

    pub fn init() Self {
        return Self{};
    }
    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn write(self: Self, parent: *rubr.naft.Node) void {
        var node = parent.node("prot.Done");
        defer node.deinit();
        if (self.exit) |exit|
            node.attr("exit", exit);
        if (self.signal) |signal|
            node.attr("signal", signal);
        if (self.stop) |stop|
            node.attr("stop", stop);
        if (self.unknown) |unknown|
            node.attr("unknown", unknown);
    }

    pub fn writeComposite(self: Self, tw: anytype) !void {
        if (self.exit) |exit|
            try tw.writeLeaf(exit, 3);
        if (self.signal) |signal|
            try tw.writeLeaf(signal, 5);
        if (self.stop) |stop|
            try tw.writeLeaf(stop, 7);
        if (self.unknown) |unknown|
            try tw.writeLeaf(unknown, 9);
    }
    pub fn readComposite(self: *Self, tr: anytype) !void {
        var tmp: u32 = undefined;
        if (try tr.readLeaf(&tmp, 3, {}))
            self.exit = tmp;
        if (try tr.readLeaf(&tmp, 5, {}))
            self.signal = tmp;
        if (try tr.readLeaf(&tmp, 7, {}))
            self.stop = tmp;
        if (try tr.readLeaf(&tmp, 9, {}))
            self.unknown = tmp;
    }
};

pub const Collect = struct {
    const Self = @This();
    pub const Id = 18;

    pub fn write(self: Self, parent: *rubr.naft.Node) void {
        _ = self;

        var node = parent.node("prot.Collect");
        defer node.deinit();
    }

    pub fn writeComposite(self: Self, tw: anytype) !void {
        _ = self;
        _ = tw;
    }
    pub fn readComposite(self: *Self, tr: anytype) !void {
        _ = self;
        _ = tr;
    }
};

pub const Bye = struct {
    const Self = @This();
    pub const Id = 20;

    a: std.mem.Allocator,
    reason: ?[]const u8 = null,

    pub fn init(a: std.mem.Allocator) Self {
        return Self{ .a = a };
    }
    pub fn deinit(self: *Self) void {
        if (self.reason) |reason|
            self.a.free(reason);
    }

    pub fn setReason(self: *Self, comptime fmt: []const u8, args: anytype) !void {
        if (self.reason != null)
            return Error.ReasonAlreadySet;
        self.reason = try std.fmt.allocPrint(self.a, fmt, args);
    }

    pub fn write(self: Self, parent: *rubr.naft.Node) void {
        var node = parent.node("prot.Bye");
        defer node.deinit();
        if (self.reason) |reason|
            node.attr("reason", reason);
    }

    pub fn writeComposite(self: Self, tw: anytype) !void {
        if (self.reason) |reason|
            try tw.writeLeaf(reason, 3);
    }
    pub fn readComposite(self: *Self, tr: anytype) !void {
        self.reason = undefined;
        if (!try tr.readLeaf(&self.reason.?, 3, self.a))
            self.reason = null;
    }
};

pub fn printMessage(obj: anytype, w: *std.Io.Writer, count: ?usize) void {
    // When `count` is provided, we only print the powers of 2
    if (@popCount(count orelse 0) <= 1) {
        var node = rubr.naft.Node.init(w);
        defer node.deinit();
        obj.write(&node);
    }
}
