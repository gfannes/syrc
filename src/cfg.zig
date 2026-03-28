const std = @import("std");
const rubr = @import("rubr.zig");

pub const Config = struct {};

pub const Aliases = struct {
    pub const Alias = struct {
        name: []const u8,
        ip: []const u8,
    };
    aliases: []Alias,
};

pub const Loader = struct {
    pub const Self = @This();

    env: rubr.Env,

    config: ?Config = null,
    aliases: ?Aliases = null,

    pub fn deinit(self: *Self) void {
        if (self.config) |config|
            std.zon.parse.free(self.env.a, config);
        if (self.aliases) |aliases|
            std.zon.parse.free(self.env.a, aliases);
    }

    pub fn load(self: *Self) !void {
        self.deinit();

        var dir = try rubr.fs.Path.home(self.env);
        try dir.add(".config");
        try dir.add("syrc");

        {
            var f = dir;
            try f.add("config.zon");
            if (f.exists(self.env)) {
                std.debug.print("Loading {s} ... ", .{f.path()});
                const content = try f.readSentinel(self.env);
                defer self.env.a.free(content);
                self.config = try std.zon.parse.fromSliceAlloc(Config, self.env.a, content, null, .{});
                std.debug.print("done\n", .{});
            }
        }

        {
            var f = dir;
            try f.add("aliases.zon");
            if (f.exists(self.env)) {
                std.debug.print("Loading {s} ... ", .{f.path()});
                const content = try f.readSentinel(self.env);
                defer self.env.a.free(content);
                self.aliases = try std.zon.parse.fromSliceAlloc(Aliases, self.env.a, content, null, .{});
                std.debug.print("done\n", .{});
            }
        }
    }
};
