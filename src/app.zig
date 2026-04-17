const std = @import("std");

const blob = @import("blob.zig");
const cfg = @import("cfg.zig");
const clnt = @import("clnt.zig");
const comm = @import("comm.zig");
const cpy = @import("cpy.zig");
const crypto = @import("crypto.zig");
const fs = @import("fs.zig");
const prot = @import("prot.zig");
const rubr = @import("rubr.zig");
const srvr = @import("srvr.zig");

pub const Error = error{
    ExpectedSync,
    ExpectedContent,
    NotImplemented,
};

pub const App = struct {
    const Self = @This();

    env: rubr.Env,
    config: *const cfg.Config,
    server: ?std.Io.net.Server = null,
    store: ?blob.Store = null,

    pub fn init(env: rubr.Env, config: *const cfg.Config) Self {
        return Self{
            .env = env,
            .config = config,
        };
    }
    pub fn deinit(self: *Self) void {
        if (self.server) |*server|
            server.deinit(self.env.io);
        if (self.store) |*store|
            store.deinit();
    }

    pub fn run(self: *Self) !void {
        try self.env.log.info("Running mode {any}\n", .{self.config.mode});

        switch (self.config.mode) {
            cfg.Mode.Client => try self.runClient(),
            cfg.Mode.Server => try self.runServer(),
            cfg.Mode.Check => try self.runCheck(),
            cfg.Mode.Test => try self.runTest(),
        }
    }

    fn runTest(self: *Self) !void {
        const addr = try self.address();

        var server = srvr.Server{
            .env = self.env,
            .address = addr,
            .store = try self.gocStore(),
            .folder = self.config.base,
            .name = "testserver",
        };
        defer server.deinit();
        try server.init();

        var server_thread = try std.Thread.spawn(.{}, srvr.Server.processOne, .{&server});
        defer server_thread.join();

        var client = clnt.Client{
            .env = self.env,
            .address = addr,
        };
        defer client.deinit();
        try client.init(self.config.base, try self.gocStore(), "testclient", null);

        client.setRunCommand(self.config.extra.items);

        var client_thread = try std.Thread.spawn(
            .{},
            comm.Session.runClient,
            .{
                &client.session,
                self.config.reset_folder,
                self.config.cleanup_folder,
                self.config.reset_store,
                self.config.collect,
                self.config.defines.items,
            },
        );
        defer client_thread.join();
    }

    fn runServer(self: *Self) !void {
        var server = srvr.Server{
            .env = self.env,
            .address = try self.address(),
            .store = try self.gocStore(),
            .folder = self.config.base,
            .name = self.config.name,
        };
        defer server.deinit();
        try server.init();

        while (true) {
            server.processOne() catch |err| {
                try self.env.log.err("Session failed: {any}\n", .{err});
                // Less robust but makes the error trace visible in debug mode
                return err;
            };
        }
    }

    fn runClient(self: *Self) !void {
        if (self.env.log.level(1)) |w|
            try rubr.flush.print(w, "app.runClient\n", .{});
        var client = clnt.Client{
            .env = self.env,
            .address = try self.address(),
        };
        defer client.deinit();
        try client.init(self.config.base, try self.gocStore(), self.config.name, self.config.suffix);

        client.setRunCommand(self.config.extra.items);

        try client.session.runClient(
            self.config.reset_folder,
            self.config.cleanup_folder,
            self.config.reset_store,
            self.config.collect,
            self.config.defines.items,
        );
    }

    fn runCheck(self: *Self) !void {
        var tree = try fs.collectTree(self.env, self.config.base);
        defer tree.deinit();

        const file = try std.Io.Dir.cwd().createFile(self.env.io, "filestates.csv", .{});
        defer file.close(self.env.io);

        var wbuf: [1024]u8 = undefined;
        var writer = file.writer(self.env.io, &wbuf);

        try writer.interface.print("path\tname\tsize\n", .{});
        for (tree.filestates.items) |filestate| {
            const str = filestate.content orelse return Error.ExpectedContent;
            try writer.interface.print("{s}\t{s}\t{}\n", .{ filestate.path orelse "", filestate.name, str.len });
        }

        try writer.interface.flush();
    }

    fn address(self: Self) !std.Io.net.IpAddress {
        std.debug.print("ip: {s}\n", .{self.config.ip});
        return try std.Io.net.IpAddress.resolve(self.env.io, self.config.ip, self.config.port);
    }

    fn gocStore(self: *Self) !*blob.Store {
        if (self.store == null) {
            if (self.env.log.level(1)) |w|
                try w.print("Creating blob store in '{s}'\n", .{self.config.store_path});
            self.store = blob.Store.init(self.env);
            try self.store.?.open(self.config.store_path);
        }
        return &self.store.?;
    }
};
