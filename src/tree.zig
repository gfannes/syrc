const std = @import("std");
const crypto = @import("crypto.zig");
const sedes = @import("sedes.zig");
const rubr = @import("rubr.zig");
const util = @import("util.zig");

pub const Error = error{
    TooLarge,
    UnexpectedData,
    ExpectedString,
    ExpectedSize,
    ExpectedChecksum,
    ExpectedFlags,
    ExpectedTimestamp,
    ExpectedFileState,
};

pub const Replicate = struct {
    const Self = @This();

    base: []const u8,
    files: []const FileState = &.{},

    pub fn write(self: Self, parent: *rubr.naft.Node) void {
        var node = parent.node("tree.Replicate");
        node.attr("base", self.base);
        for (self.files) |item|
            item.write(&node);
    }

    pub fn writeComposite(self: Self, tw: anytype) !void {
        try tw.writeLeaf(self.base);
        try tw.writeLeaf(self.files.len);
        for (self.files) |file| {
            try tw.writeComposite(file);
        }
    }
    pub fn readComposite(self: *Self, tr: anytype, a: std.mem.Allocator) !void {
        if (!try tr.readLeaf(&self.base, a))
            return Error.ExpectedString;

        var size: usize = undefined;
        if (!try tr.readLeaf(&size, {}))
            return Error.ExpectedSize;

        const files = try a.alloc(FileState, size);
        for (files) |*file| {
            if (!try tr.readComposite(file, a))
                return Error.ExpectedFileState;
        }
        self.files = files;

        if (!try tr.isClose())
            return Error.UnexpectedData;
    }
};

pub const FileState = struct {
    const Self = @This();

    a: std.mem.Allocator,
    path: []const u8 = &.{},
    content: ?[]const u8 = null,
    checksum: ?crypto.Checksum = null,
    attributes: Attributes = .{},
    timestamp: Timestamp = 0,

    pub fn init(a: std.mem.Allocator) Self {
        return Self{ .a = a };
    }
    pub fn deinit(self: *Self) void {
        self.a.free(self.path);
        if (self.content) |data|
            self.a.free(data);
    }

    pub fn writeComposite(self: Self, tw: anytype) !void {
        try tw.writeLeaf(self.path);

        const checksum: []const u8 = if (self.checksum) |cs| &cs else &.{};
        try tw.writeLeaf(checksum);

        {
            var flags: u3 = 0;
            flags <<= 1;
            flags += if (self.attributes.read) 1 else 0;
            flags <<= 1;
            flags += if (self.attributes.write) 1 else 0;
            flags <<= 1;
            flags += if (self.attributes.execute) 1 else 0;
            try tw.writeLeaf(flags);
        }

        try tw.writeLeaf(self.timestamp);
    }
    pub fn readComposite(self: *Self, tr: anytype, a: std.mem.Allocator) !void {
        if (!try tr.readLeaf(&self.path, a))
            return Error.ExpectedString;

        var checksum: []const u8 = undefined;
        if (!try tr.readLeaf(&checksum, a))
            return Error.ExpectedChecksum;
        a.free(checksum);

        var flags: u3 = undefined;
        if (!try tr.readLeaf(&flags, {}))
            return Error.ExpectedFlags;

        if (!try tr.readLeaf(&self.timestamp, {}))
            return Error.ExpectedTimestamp;
    }

    pub fn write(self: Self, parent: *rubr.naft.Node) void {
        var node = parent.node("tree.FileState");
        node.attr("path", self.path);
        if (self.content) |content|
            node.attr("content", content);
        if (self.checksum) |checksum| {
            var buffer: [2 * 20]u8 = undefined;
            for (checksum, 0..) |byte, ix0| {
                const ix = 2 * ix0;
                _=std.fmt.bufPrint(buffer[ix .. ix + 2], "{x:0>2}", .{byte}) catch unreachable;
            }
            node.attr("checksum", &buffer);
        }
    }
};

pub const Attributes = struct {
    read: bool = true,
    write: bool = false,
    execute: bool = false,
};

pub const Timestamp = u32;
