const std = @import("std");
const tree = @import("tree.zig");
const util = @import("util.zig");

pub const Error = error{
    TooLarge,
};

pub fn writeInt(T: type, value: T, writer: anytype) !void {
    var buffer: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &buffer, value, .big);
    try writer.writeAll(&buffer);
}
pub fn writeString(str: []const u8, writer: anytype) !void {
    const len = std.math.cast(u32, str.len) orelse return Error.TooLarge;
    try writeInt(u32, len, writer);
    try writer.writeAll(str);
}
pub fn writeComposite(obj: anytype, writer: anytype) !void {
    var counter = Counter{};
    try obj.write(&counter);
    const size = std.math.cast(u32, counter.size) orelse return Error.TooLarge;
    try writeInt(u32, size, writer);
    try obj.write(writer);
}

pub const Counter = struct {
    const Self = @This();

    size: usize = 0,

    pub fn writeAll(self: *Self, ary: []const u8) !void {
        self.size += ary.len;
    }
};

pub const Writer = struct {
    const Self = @This();

    pub fn init() Self {
        return Self{};
    }
    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn write(self: *Self, obj: anytype, id: u32, writer: anytype) !void {
        _ = self;

        const version: u32 = 1;
        try writeInt(u32, version, writer);
        try writeInt(u32, getType(@TypeOf(obj)), writer);
        try writeInt(u32, id, writer);

        try obj.write(writer);
    }
};

pub const Reader = struct {
    const Self = @This();

    pub fn init() Self {
        return Self{};
    }
    pub fn deinit(self: *Self) void {
        _ = self;
    }
};

fn getType(comptime T: type) u32 {
    return switch (util.baseType(T)) {
        tree.Replicate => 1,
        else => @compileError("Unsupported type '" ++ @typeName(T) ++ "'"),
    };
}
