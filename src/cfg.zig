const std = @import("std");
const rubr = @import("rubr.zig");

pub const Config = struct {
    const Self = @This();

    env: rubr.Env,

    pub fn init(env: rubr.Env) Self {
        return Self{ .env = env };
    }
    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn load(self: *Self) !void {
        var dir = try rubr.fs.Path.home(self.env);
        try dir.add(".config");
        try dir.add("syrc");
        try dir.add("config.zon");
        std.debug.print("Config path: {s}\n", .{dir.path()});
    }
};

pub const Aliases = struct {
    pub const Alias = struct {
        name: []const u8,
        ip: []const u8,
    };
};
