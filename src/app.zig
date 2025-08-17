const std = @import("std");
const cli = @import("cli.zig");
const rubr = @import("rubr.zig");
const tree = @import("tree.zig");
const prot = @import("prot.zig");
const crypto = @import("crypto.zig");

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

    pub fn init(a: std.mem.Allocator, log: *const rubr.log.Log, mode: cli.Mode, ip: ?[]const u8, port: ?u16) Self {
        return Self{ .a = a, .log = log, .mode = mode, .ip = ip, .port = port };
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
            .base = "tmp",
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

            const tw = rubr.comm.TreeWriter(std.fs.File){ .out = file };

            try tw.writeComposite(&replicate, 2);
        }
        {
            const file = try std.fs.cwd().openFile("output.dat", .{});
            defer file.close();

            var tr = rubr.comm.TreeReader(std.fs.File){ .in = file };

            var rep: prot.Replicate = undefined;
            var aa = std.heap.ArenaAllocator.init(self.a);
            defer aa.deinit();
            if (!try tr.readComposite(&rep, 2, aa.allocator()))
                return Error.ExpectedReplicate;
        }
    }
    fn runServer(self: *Self) !void {
        const addr = try self.address();
        if (self.log.level(1)) |w|
            try w.print("Creating server on {}\n", .{addr});
        var server = try addr.listen(.{});
        defer server.deinit();

        while (true) {
            if (self.log.level(1)) |w|
                try w.print("Waiting for connection...\n", .{});

            var connection = try server.accept();
            defer connection.stream.close();
            if (self.log.level(1)) |w|
                try w.print("Received connection {}\n", .{connection.address});

            var tr = rubr.comm.TreeReader(std.net.Stream){ .in = connection.stream };

            var replicate: prot.Replicate = undefined;
            var aa = std.heap.ArenaAllocator.init(self.a);
            defer aa.deinit();
            if (!try tr.readComposite(&replicate, 2, aa.allocator()))
                return Error.ExpectedReplicate;

            if (self.log.level(1)) |w| {
                var root = rubr.naft.Node.init(w);
                replicate.write(&root);
            }
        }
    }
    fn runClient(self: *Self) !void {
        var replicate: prot.Replicate = .{
            .a = self.a,
            .base = "tmp",
            .files = try tree.collectFileStates(std.fs.cwd(), self.a),
        };
        defer replicate.deinit();

        if (self.log.level(1)) |w| {
            var root = rubr.naft.Node.init(w);
            replicate.write(&root);
        }

        const addr = try self.address();
        if (self.log.level(1)) |w|
            try w.print("Connecting to {}\n", .{addr});
        var stream = try std.net.tcpConnectToAddress(addr);
        defer stream.close();

        const tw = rubr.comm.TreeWriter(std.net.Stream){ .out = stream };

        try tw.writeComposite(&replicate, 2);
    }

    fn address(self: Self) !std.net.Address {
        const ip = self.ip orelse return Error.ExpectedIp;
        const port = self.port orelse return Error.ExpectedPort;
        return try std.net.Address.resolveIp(ip, port);
    }
};
