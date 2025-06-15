const std = @import("std");
const cli = @import("cli.zig");

pub const Error = error{
    ExpectedIp,
    ExpectedPort,
};

pub const App = struct {
    const Self = @This();

    a: std.mem.Allocator,
    mode: cli.Mode,
    ip: ?[]const u8 = null,
    port: ?u16 = null,
    server: ?std.net.Server = null,

    pub fn init(a: std.mem.Allocator, mode: cli.Mode, ip: ?[]const u8, port: ?u16) Self {
        return Self{ .a = a, .mode = mode, .ip = ip, .port = port };
    }
    pub fn deinit(self: *Self) void {
        if (self.server) |*server|
            server.deinit();
    }

    pub fn run(self: *Self) !void {
        if (self.mode == cli.Mode.Server or self.mode == cli.Mode.Broker) {
            const ip = self.ip orelse return Error.ExpectedIp;
            const port = self.port orelse return Error.ExpectedPort;
            const address = std.net.Address.resolveIp(ip, port);
            _ = address;
        }
    }
};
