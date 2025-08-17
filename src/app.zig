const std = @import("std");
const cli = @import("cli.zig");
const rubr = @import("rubr.zig");
const tree = @import("tree.zig");
const prot = @import("prot.zig");
const crypto = @import("crypto.zig");

pub const Error = error{
    ExpectedIp,
    ExpectedPort,
    ExpectedHello,
    ExpectedReplicate,
    ExpectedRun,
    ExpectedBye,
    UnknownId,
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

    fn printMessage(self: Self, msg: anytype) !void {
        if (self.log.level(1)) |w| {
            try w.print("\nReceived message:\n", .{});
            var root = rubr.naft.Node.init(w);
            msg.write(&root);
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

            var quit = false;
            while (!quit) {
                var aa = std.heap.ArenaAllocator.init(self.a);
                defer aa.deinit();

                const a = aa.allocator();

                const header = try tr.readHeader();
                switch (header.id) {
                    prot.Hello.Id => {
                        const T = prot.Hello;
                        var msg: T = undefined;
                        if (!try tr.readComposite(&msg, T.Id, {}))
                            return Error.ExpectedHello;
                        try self.printMessage(msg);
                    },
                    prot.Replicate.Id => {
                        const T = prot.Replicate;
                        var msg = T.init(a);
                        defer msg.deinit();
                        if (!try tr.readComposite(&msg, T.Id, a))
                            return Error.ExpectedReplicate;
                        try self.printMessage(msg);
                    },
                    prot.Run.Id => {
                        const T = prot.Run;
                        var msg = T.init(a);
                        defer msg.deinit();
                        if (!try tr.readComposite(&msg, T.Id, a))
                            return Error.ExpectedRun;
                        try self.printMessage(msg);
                    },
                    prot.Bye.Id => {
                        const T = prot.Bye;
                        var msg: T = undefined;
                        if (!try tr.readComposite(&msg, T.Id, {}))
                            return Error.ExpectedBye;
                        try self.printMessage(msg);

                        if (self.log.level(1)) |w|
                            try w.print("Closing connection\n", .{});
                        quit = true;
                    },
                    else => {
                        try self.log.err("Unknown Id {}\n", .{header.id});
                        return Error.UnknownId;
                    },
                }
            }
        }
    }
    fn runClient(self: *Self) !void {
        const addr = try self.address();
        if (self.log.level(1)) |w|
            try w.print("Connecting to {}\n", .{addr});
        var stream = try std.net.tcpConnectToAddress(addr);
        defer stream.close();

        const tw = rubr.comm.TreeWriter(std.net.Stream){ .out = stream };

        {
            const T = prot.Hello;
            try tw.writeComposite(T{ .role = T.Role.Client, .status = T.Status.Pending }, T.Id);
        }

        {
            const T = prot.Replicate;
            var msg = T.init(self.a);
            defer msg.deinit();
            msg.base = try msg.a.dupe(u8, "tmp");
            msg.files = try tree.collectFileStates(std.fs.cwd(), self.a);

            try tw.writeComposite(msg, T.Id);
        }

        {
            const T = prot.Run;
            var msg = T.init(self.a);
            defer msg.deinit();
            msg.cmd = try msg.a.dupe(u8, "rake");
            try msg.args.append(try msg.a.dupe(u8, "ut"));

            try tw.writeComposite(msg, T.Id);
        }

        {
            const T = prot.Bye;
            try tw.writeComposite(T{}, T.Id);
        }
    }

    fn address(self: Self) !std.net.Address {
        const ip = self.ip orelse return Error.ExpectedIp;
        const port = self.port orelse return Error.ExpectedPort;
        return try std.net.Address.resolveIp(ip, port);
    }
};
