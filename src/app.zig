const std = @import("std");
const cli = @import("cli.zig");
const rubr = @import("rubr.zig");
const tree = @import("tree.zig");
const prot = @import("prot.zig");
const crypto = @import("crypto.zig");
const srvr = @import("srvr.zig");
const clnt = @import("clnt.zig");

pub const Error = error{
    ExpectedIp,
    ExpectedPort,
    ExpectedReplicate,
    NotImplemented,
};

pub const App = struct {
    const Self = @This();

    a: std.mem.Allocator,
    log: *const rubr.log.Log,
    mode: cli.Mode,
    ip: ?[]const u8 = null,
    port: ?u16 = null,
    server: ?std.net.Server = null,
    base: []const u8,
    extra: []const []const u8,

    pub fn init(a: std.mem.Allocator, log: *const rubr.log.Log, mode: cli.Mode, ip: ?[]const u8, port: ?u16, base: []const u8, extra: []const []const u8) Self {
        return Self{
            .a = a,
            .log = log,
            .mode = mode,
            .ip = ip,
            .port = port,
            .base = base,
            .extra = extra,
        };
    }
    pub fn deinit(self: *Self) void {
        if (self.server) |*server|
            server.deinit();
    }

    pub fn run(self: *Self) !void {
        try self.log.info("Running mode {any}\n", .{self.mode});

        switch (self.mode) {
            cli.Mode.Server => try self.runServer(),
            cli.Mode.Client => try self.runClient(),
            cli.Mode.Test => try self.runTest(),
            cli.Mode.Broker => return Error.NotImplemented,
        }
    }

    fn runTest(self: *Self) !void {
        var replicate: prot.Replicate = .{
            .a = self.a,
            .base = try self.a.dupe(u8, "tmp"),
            .files = try tree.collectFileStates(std.fs.cwd(), self.a),
        };
        defer replicate.deinit();

        if (self.log.level(1)) |w| {
            var root = rubr.naft.Node.init(w);
            replicate.write(&root);
        }

        {
            const file = try std.fs.cwd().createFile("output.dat", .{});
            defer file.close();

            var buffer: [1024]u8 = undefined;
            var writer = file.writer(&buffer);

            const tw = rubr.comm.TreeWriter{ .out = &writer.interface };

            try tw.writeComposite(&replicate, prot.Replicate.Id);
        }

        {
            const file = try std.fs.cwd().openFile("output.dat", .{});
            defer file.close();

            var buffer: [1024]u8 = undefined;
            var reader = file.reader(&buffer);

            var tr = rubr.comm.TreeReader{ .in = &reader.interface };

            var aa = std.heap.ArenaAllocator.init(self.a);
            defer aa.deinit();

            var rep = prot.Replicate.init(aa.allocator());
            defer rep.deinit();
            if (!try tr.readComposite(&rep, prot.Replicate.Id))
                return Error.ExpectedReplicate;
        }
    }

    fn runServer(self: *Self) !void {
        const addr = try self.address();
        if (self.log.level(1)) |w|
            try w.print("Creating server on {f}\n", .{addr});
        var server = try addr.listen(.{});
        defer server.deinit();

        while (true) {
            if (self.log.level(1)) |w|
                try w.print("Waiting for connection...\n", .{});

            var connection = try server.accept();
            defer connection.stream.close();
            if (self.log.level(1)) |w|
                try w.print("Received connection {f}\n", .{connection.address});

            var session = srvr.Session{ .a = self.a, .log = self.log };
            session.init(connection.stream);
            defer session.deinit();

            try session.execute();

            // break;
        }
    }
    fn runClient(self: *Self) !void {
        const addr = try self.address();
        if (self.log.level(1)) |w|
            try w.print("Connecting to {f}\n", .{addr});
        var stream = try std.net.tcpConnectToAddress(addr);
        defer stream.close();

        var session = clnt.Session{ .a = self.a, .log = self.log, .base = self.base };
        session.init(stream);
        defer session.deinit();

        session.setArgv(self.extra);

        try session.execute();
    }

    fn address(self: Self) !std.net.Address {
        const ip = self.ip orelse return Error.ExpectedIp;
        const port = self.port orelse return Error.ExpectedPort;
        return try std.net.Address.resolveIp(ip, port);
    }
};
