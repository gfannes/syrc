const std = @import("std");
const rubr = @import("rubr.zig");

pub const Config = struct {
    pub const Alias = struct {
        name: []const u8,
        ip: []const u8,
    };

    name: ?[]const u8 = null,
    aliases: []Alias = &.{},
};

pub const Loader = struct {
    pub const Self = @This();

    env: rubr.Env,

    config: ?Config = null,

    pub fn deinit(self: *Self) void {
        if (self.config) |config|
            std.zon.parse.free(self.env.a, config);
    }

    pub fn load(self: *Self) !void {
        self.deinit();

        var f = try rubr.fs.Path.home(self.env);
        try f.add(".config");
        try f.add("syrc");
        try f.add("config.zon");

        if (f.exists(self.env)) {
            std.debug.print("Loading {s} ... ", .{f.path()});
            const content = try f.readSentinel(self.env);
            defer self.env.a.free(content);
            self.config = try std.zon.parse.fromSliceAlloc(Config, self.env.a, content, null, .{});
            std.debug.print("done\n", .{});
        }
    }
};
