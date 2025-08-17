const std = @import("std");
const crypto = @import("crypto.zig");
const rubr = @import("rubr.zig");

pub const Error = error{
    TooLarge,
    UnexpectedData,
    ExpectedString,
    ExpectedSize,
    ExpectedContent,
    ExpectedChecksum,
    ExpectedFlags,
    ExpectedTimestamp,
    ExpectedFileState,
    WrongChecksumSize,
};

pub const Replicate = struct {
    const Self = @This();

    base: []const u8,
    files: []const FileState = &.{},

    pub fn write(self: Self, parent: *rubr.naft.Node) void {
        var node = parent.node("tree.Replicate");
        defer node.deinit();
        node.attr("base", self.base);
        for (self.files) |item|
            item.write(&node);
    }

    pub fn writeComposite(self: Self, tw: anytype) !void {
        try tw.writeLeaf(self.base, 3);
        try tw.writeLeaf(self.files.len, 3);
        for (self.files) |file| {
            try tw.writeComposite(file, 2);
        }
    }
    pub fn readComposite(self: *Self, tr: anytype, a: std.mem.Allocator) !void {
        if (!try tr.readLeaf(&self.base, 3, a))
            return Error.ExpectedString;

        var size: usize = undefined;
        if (!try tr.readLeaf(&size, 3, {}))
            return Error.ExpectedSize;

        const files = try a.alloc(FileState, size);
        for (files) |*file| {
            file.* = FileState.init(a);
            if (!try tr.readComposite(file, 2, a))
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
        try tw.writeLeaf(self.path, 3);

        {
            var flags: u3 = 0;
            flags <<= 1;
            flags += if (self.attributes.read) 1 else 0;
            flags <<= 1;
            flags += if (self.attributes.write) 1 else 0;
            flags <<= 1;
            flags += if (self.attributes.execute) 1 else 0;
            try tw.writeLeaf(flags, 3);
        }

        try tw.writeLeaf(self.timestamp, 3);

        if (self.content) |content|
            try tw.writeLeaf(content, 5);

        if (self.checksum) |cs|
            try tw.writeLeaf(&cs, 7);
    }
    pub fn readComposite(self: *Self, tr: anytype, a: std.mem.Allocator) !void {
        if (!try tr.readLeaf(&self.path, 3, a))
            return Error.ExpectedString;

        var flags: u3 = undefined;
        if (!try tr.readLeaf(&flags, 3, {}))
            return Error.ExpectedFlags;

        if (!try tr.readLeaf(&self.timestamp, 3, {}))
            return Error.ExpectedTimestamp;

        while (true) {
            const header = try tr.readHeader();
            switch (header.id) {
                5 => {
                    self.content = undefined;
                    if (!try tr.readLeaf(&self.content.?, header.id, a))
                        return Error.ExpectedContent;
                },
                7 => {
                    var checksum: []const u8 = undefined;
                    if (!try tr.readLeaf(&checksum, 7, a))
                        return Error.ExpectedChecksum;
                    if (checksum.len != @sizeOf(crypto.Checksum))
                        return Error.WrongChecksumSize;
                    self.checksum = undefined;
                    if (self.checksum) |*cs|
                        std.mem.copyForwards(u8, cs, checksum);
                },
                else => break,
            }
        }
    }

    pub fn write(self: Self, parent: *rubr.naft.Node) void {
        var node = parent.node("tree.FileState");
        defer node.deinit();
        node.attr("path", self.path);
        if (self.content) |content|
            node.attr("content", content);
        if (self.checksum) |checksum| {
            var buffer: [2 * 20]u8 = undefined;
            for (checksum, 0..) |byte, ix0| {
                const ix = 2 * ix0;
                _ = std.fmt.bufPrint(buffer[ix .. ix + 2], "{x:0>2}", .{byte}) catch unreachable;
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
