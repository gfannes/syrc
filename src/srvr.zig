// &todo: Rename into Sink

const std = @import("std");
const prot = @import("prot.zig");
const comm = @import("comm.zig");
const blob = @import("blob.zig");
const rubr = @import("rubr.zig");
const Env = rubr.Env;

pub const Error = error{
    ExpectedListeningServer,
};

pub const Server = struct {
    const Self = @This();

    env: Env,
    address: std.Io.net.IpAddress,
    store: *blob.Store,
    folder: []const u8,

    server: ?std.Io.net.Server = null,

    pub fn init(self: *Self) !void {
        if (self.env.log.level(1)) |w|
            try w.print("Creating server on {f}\n", .{self.address});
        self.server = try self.address.listen(self.env.io, .{ .reuse_address = true });
    }

    pub fn deinit(self: *Self) void {
        if (self.server) |*server|
            server.deinit(self.env.io);
    }

    pub fn processOne(self: *Self) !void {
        var server = self.server orelse return Error.ExpectedListeningServer;

        if (self.env.log.level(1)) |w| {
            try w.print("\nWaiting for connection...\n", .{});
            try w.flush();
        }

        var session = comm.Session{
            .env = self.env,
            .store = self.store,
            .base = self.folder,
        };
        defer session.deinit();

        {
            var stream = try server.accept(self.env.io);
            errdefer stream.close(self.env.io);
            if (self.env.log.level(1)) |w|
                try w.print("Received connection {f}\n", .{stream.socket.address});

            try session.init(stream);
        }

        try session.runServer();
    }
};
