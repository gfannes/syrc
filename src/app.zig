const std = @import("std");

pub const App = struct {
    const Self = @This();

    a: std.mem.Allocator,

    pub fn init(a: std.mem.Allocator) Self {
        return Self{ .a = a };
    }
    pub fn deinit(self: *Self) void {
        _ = self;
    }
};
