const std = @import("std");
const cli = @import("cli.zig");
const rubr = @import("rubr.zig");
const tree = @import("tree.zig");
const prot = @import("prot.zig");
const crypto = @import("crypto.zig");
const srvr = @import("srvr.zig");
const clnt = @import("clnt.zig");
const cpy = @import("cpy.zig");
const blob = @import("blob.zig");
const Env = rubr.Env;

pub const Error = error{
    ExpectedIp,
    ExpectedPort,
    ExpectedReplicate,
    ExpectedSrc,
    ExpectedChecksum,
    NotImplemented,
};

pub const App = struct {
    const Self = @This();

    env: Env,
    mode: cli.Mode,
    ip: ?[]const u8 = null,
    port: ?u16 = null,
    server: ?std.Io.net.Server = null,
    base: []const u8,
    src: ?[]const u8,
    store_absdir: []const u8,
    extra: []const []const u8,

    store: ?blob.Store = null,

    pub fn init(env: Env, mode: cli.Mode, ip: ?[]const u8, port: ?u16, base: []const u8, src: ?[]const u8, store_absdir: []const u8, extra: []const []const u8) Self {
        return Self{
            .env = env,
            .mode = mode,
            .ip = ip,
            .port = port,
            .base = base,
            .src = src,
            .store_absdir = store_absdir,
            .extra = extra,
        };
    }
    pub fn deinit(self: *Self) void {
        if (self.server) |*server|
            server.deinit(self.env.io);
        if (self.store) |*store|
            store.deinit();
    }

    pub fn run(self: *Self) !void {
        try self.env.log.info("Running mode {any}\n", .{self.mode});

        switch (self.mode) {
            cli.Mode.Client => try self.runClient(),
            cli.Mode.Server => try self.runServer(),
            cli.Mode.Copy => try self.runCopy(),
            cli.Mode.Test => try self.runTest(),
            cli.Mode.Broker => return Error.NotImplemented,
        }
    }

    fn runCopy(self: *Self) !void {
        std.debug.print("runCopy {?s}\n", .{self.src});
        var src_dir = try std.fs.openDirAbsolute(self.src orelse return Error.ExpectedSrc, .{});
        defer src_dir.close();

        var replicate: prot.Replicate = .{
            .a = self.env.a,
            .base = try self.env.a.dupe(u8, "tmp"),
            .files = try tree.collectFileStates(src_dir, self.env),
        };
        defer replicate.deinit();

        if (self.env.log.level(1)) |w| {
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
            var reader = file.reader(self.env.io, &buffer);

            var tr = rubr.comm.TreeReader{ .in = &reader.interface };

            var aa = std.heap.ArenaAllocator.init(self.env.a);
            defer aa.deinit();

            var rep = prot.Replicate.init(aa.allocator());
            defer rep.deinit();
            if (!try tr.readComposite(&rep, prot.Replicate.Id))
                return Error.ExpectedReplicate;
        }
    }

    fn runTest(self: *Self) !void {
        const addr = try self.address();

        var server = srvr.Server{
            .env = self.env,
            .address = addr,
            .store = try self.gocStore(),
        };
        defer server.deinit();
        try server.init();

        var server_thread = try std.Thread.spawn(.{}, srvr.Server.processOne, .{&server});
        defer server_thread.join();

        var client = clnt.Session{
            .env = self.env,
            .address = addr,
            .base = self.base,
            .src = self.src orelse return Error.ExpectedSrc,
        };
        defer client.deinit();
        try client.init();

        var client_thread = try std.Thread.spawn(.{}, clnt.Session.execute, .{&client});
        defer client_thread.join();
    }

    fn runServer(self: *Self) !void {
        var server = srvr.Server{
            .env = self.env,
            .address = try self.address(),
            .store = try self.gocStore(),
        };
        defer server.deinit();
        try server.init();

        while (true) {
            try server.processOne();
            // break;
        }
    }

    fn runClient(self: *Self) !void {
        var session = clnt.Session{
            .env = self.env,
            .address = try self.address(),
            .base = self.base,
            .src = self.src orelse return Error.ExpectedSrc,
        };
        try session.init();
        defer session.deinit();

        session.setArgv(self.extra);

        try session.execute();
    }

    fn address(self: Self) !std.Io.net.IpAddress {
        const ip = self.ip orelse return Error.ExpectedIp;
        const port = self.port orelse return Error.ExpectedPort;
        return try std.Io.net.IpAddress.resolve(self.env.io, ip, port);
    }

    fn gocStore(self: *Self) !*blob.Store {
        if (self.store == null) {
            self.store = blob.Store.init(self.env.a);
        }
        return &self.store.?;
    }
};
