const std = @import("std");

pub const Writer = struct {
    const Self = @This();

    pub fn init() Self {
        return Self{};
    }
    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn write(self: *Self, writer: anytype, obj: anytype) !void {
        _ = self;
        _ = obj;
        const version: u32 = 1;
        const buffer: [4]u8 = undefined;
        std.mem.writeInt(u32, &buffer, version, .big);
        try writer.writeAll(&buffer);
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
