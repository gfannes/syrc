const std = @import("std");
const cli = @import("cli.zig");
const rubr = @import("rubr.zig");

pub const Error = error{
    ExpectedIp,
    ExpectedPort,
};

pub const App = struct {
    const Self = @This();

    a: std.mem.Allocator,
    log: *const rubr.log.Log,
    mode: cli.Mode,
    ip: ?[]const u8 = null,
    port: ?u16 = null,
    server: ?std.net.Server = null,

    pub fn init(a: std.mem.Allocator, log: *const rubr.log.Log, mode: cli.Mode, ip: ?[]const u8, port: ?u16) Self {
        return Self{ .a = a, .log = log, .mode = mode, .ip = ip, .port = port };
    }
    pub fn deinit(self: *Self) void {
        if (self.server) |*server|
            server.deinit();
    }

    pub fn run(self: *Self) !void {
        try self.log.info("Running mode {any}\n", .{self.mode});
        if (self.mode == cli.Mode.Server or self.mode == cli.Mode.Broker) {
            const ip = self.ip orelse return Error.ExpectedIp;
            const port = self.port orelse return Error.ExpectedPort;
            const address = try std.net.Address.resolveIp(ip, port);
            _ = address;
        }

        var walker = rubr.walker.Walker.init(self.a);
        defer walker.deinit();

        var cb = struct {
            const My = @This();
            pub fn call(my: *My, dir: std.fs.Dir, path: []const u8, offset: ?rubr.walker.Offsets, kind: rubr.walker.Kind) !void {
                _ = my;
                _ = dir;
                _ = offset;
                _ = kind;
                std.debug.print("Path: {s}\n", .{path});
            }
        }{};
        try walker.walk(std.fs.cwd(), &cb);
    }
};
