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
    ExpectedSync,
    ExpectedSrc,
    ExpectedContent,
    NotImplemented,
};

pub const App = struct {
    const Self = @This();

    env: Env,
    mode: cli.Mode,
    ip: ?[]const u8 = null,
    port: ?u16 = null,
    server: ?std.Io.net.Server = null,
    subdir: []const u8,
    reset: bool,
    cleanup: bool,
    src: ?[]const u8,
    store_absdir: []const u8,
    extra: []const []const u8,

    store: ?blob.Store = null,

    pub fn init(env: Env, mode: cli.Mode, ip: ?[]const u8, port: ?u16, subdir: []const u8, reset: bool, cleanup: bool, src: ?[]const u8, store_absdir: []const u8, extra: []const []const u8) Self {
        return Self{
            .env = env,
            .mode = mode,
            .ip = ip,
            .port = port,
            .subdir = subdir,
            .reset = reset,
            .cleanup = cleanup,
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
            cli.Mode.Check => try self.runCheck(),
            cli.Mode.Test => try self.runTest(),
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
            .subdir = self.subdir,
            .reset = self.reset,
            .cleanup = self.cleanup,
            .src = self.src orelse return Error.ExpectedSrc,
        };
        defer client.deinit();
        try client.init();

        client.setArgv(self.extra);

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
            .subdir = self.subdir,
            .reset = self.reset,
            .cleanup = self.cleanup,
            .src = self.src orelse return Error.ExpectedSrc,
        };
        try session.init();
        defer session.deinit();

        session.setArgv(self.extra);

        try session.execute();
    }

    fn runCheck(self: *Self) !void {
        const src = self.src orelse return Error.ExpectedSrc;

        var src_dir = try std.fs.openDirAbsolute(src, .{});
        defer src_dir.close();

        var filestates = try tree.collectFileStates(self.env, src_dir);
        defer {
            for (filestates.items) |*filestate|
                filestate.deinit();
            filestates.deinit(self.env.a);
        }

        const file = try std.fs.cwd().createFile("filestates.csv", .{});
        defer file.close();

        var buf: [1024]u8 = undefined;
        var writer = file.writer(&buf);

        try writer.interface.print("path\tname\tsize\n", .{});
        for (filestates.items) |filestate| {
            const str = filestate.content orelse return Error.ExpectedContent;
            try writer.interface.print("{s}\t{s}\t{}\n", .{ filestate.path orelse "", filestate.name, str.len });
        }

        try writer.interface.flush();
    }

    fn address(self: Self) !std.Io.net.IpAddress {
        const ip = self.ip orelse return Error.ExpectedIp;
        const port = self.port orelse return Error.ExpectedPort;
        return try std.Io.net.IpAddress.resolve(self.env.io, ip, port);
    }

    fn gocStore(self: *Self) !*blob.Store {
        if (self.store == null) {
            if (self.env.log.level(1)) |w|
                try w.print("Creating blob store in '{s}'\n", .{self.store_absdir});
            self.store = blob.Store.init(self.env.a);
            try self.store.?.open(self.store_absdir);
        }
        return &self.store.?;
    }
};
