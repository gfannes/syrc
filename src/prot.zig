const std = @import("std");
const tree = @import("tree.zig");
const rubr = @import("rubr.zig");

pub const Error = error{
    ExpectedString,
    ExpectedSize,
    ExpectedFileState,
    UnexpectedData,
};

pub const Hello = struct {
    const Self = @This();

    pub fn init() Self {
        return Self{};
    }
    pub fn deinit(self: *Self) void {
        _ = self;
    }
    pub fn writeComposite(self: Self, tw: anytype) !void {
        _ = self;
        _ = tw;
    }
    pub fn readComposite(self: *Self, tr: anytype, a: std.mem.Allocator) !void {
        _ = self;
        _ = tr;
        _ = a;
    }
};

pub const Replicate = struct {
    const Self = @This();

    a: std.mem.Allocator,
    base: []const u8,
    files: tree.FileStates,

    pub fn init(a: std.mem.Allocator) Self {
        return Self{ .a = a, .files = tree.FileStates.init(a) };
    }
    pub fn deinit(self: *Self) void {
        for (self.files.items) |*item|
            item.deinit();
        self.files.deinit();
    }

    pub fn write(self: Self, parent: *rubr.naft.Node) void {
        var node = parent.node("tree.Replicate");
        defer node.deinit();
        node.attr("base", self.base);
        for (self.files.items) |item|
            item.write(&node);
    }

    pub fn writeComposite(self: Self, tw: anytype) !void {
        try tw.writeLeaf(self.base, 3);
        try tw.writeLeaf(self.files.items.len, 3);
        for (self.files.items) |file| {
            try tw.writeComposite(file, 2);
        }
    }
    pub fn readComposite(self: *Self, tr: anytype, a: std.mem.Allocator) !void {
        if (!try tr.readLeaf(&self.base, 3, a))
            return Error.ExpectedString;

        var size: usize = undefined;
        if (!try tr.readLeaf(&size, 3, {}))
            return Error.ExpectedSize;

        var files = tree.FileStates.init(a);
        try files.resize(size);
        for (files.items) |*file| {
            file.* = tree.FileState.init(a);
            if (!try tr.readComposite(file, 2, a))
                return Error.ExpectedFileState;
        }
        self.files = files;

        if (!try tr.isClose())
            return Error.UnexpectedData;
    }
};
