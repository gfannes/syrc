const std = @import("std");
const cli = @import("cli.zig");
const rubr = @import("rubr.zig");
const fs = @import("fs.zig");
const prot = @import("prot.zig");
const crypto = @import("crypto.zig");
const srvr = @import("srvr.zig");
const clnt = @import("clnt.zig");
const comm = @import("comm.zig");
const cpy = @import("cpy.zig");
const blob = @import("blob.zig");
const Env = rubr.Env;

pub const Error = error{
    ExpectedSync,
    ExpectedContent,
    NotImplemented,
};

pub const App = struct {
    const Self = @This();

    env: Env,
    args: cli.Args,
    server: ?std.Io.net.Server = null,
    store: ?blob.Store = null,

    pub fn init(env: Env, args: cli.Args) Self {
        return Self{
            .env = env,
            .args = args,
        };
    }
    pub fn deinit(self: *Self) void {
        if (self.server) |*server|
            server.deinit(self.env.io);
        if (self.store) |*store|
            store.deinit();
    }

    pub fn run(self: *Self) !void {
        try self.env.log.info("Running mode {any}\n", .{self.args.mode});

        switch (self.args.mode) {
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
            .folder = self.args.base,
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
        try client.init(self.args.base, try self.gocStore());

        client.setRunCommand(self.args.extra.items);

        var client_thread = try std.Thread.spawn(
            .{},
            comm.Session.runClient,
            .{
                &client.session,
                self.args.name,
                self.args.reset_folder,
                self.args.cleanup_folder,
                self.args.reset_store,
                self.args.collect,
            },
        );
        defer client_thread.join();
    }

    fn runServer(self: *Self) !void {
        var server = srvr.Server{
            .env = self.env,
            .address = try self.address(),
            .store = try self.gocStore(),
            .folder = self.args.base,
        };
        defer server.deinit();
        try server.init();

        while (true) {
            try server.processOne();
            // break;
        }
    }

    fn runClient(self: *Self) !void {
        var client = clnt.Client{
            .env = self.env,
            .address = try self.address(),
        };
        defer client.deinit();
        try client.init(self.args.base, try self.gocStore());

        client.setRunCommand(self.args.extra.items);

        try client.session.runClient(
            self.args.name,
            self.args.reset_folder,
            self.args.cleanup_folder,
            self.args.reset_store,
            self.args.collect,
        );
    }

    fn runCheck(self: *Self) !void {
        var tree = try fs.collectTree(self.env, self.args.base);
        defer tree.deinit();

        const file = try std.fs.cwd().createFile("filestates.csv", .{});
        defer file.close();

        var buf: [1024]u8 = undefined;
        var writer = file.writer(&buf);

        try writer.interface.print("path\tname\tsize\n", .{});
        for (tree.filestates.items) |filestate| {
            const str = filestate.content orelse return Error.ExpectedContent;
            try writer.interface.print("{s}\t{s}\t{}\n", .{ filestate.path orelse "", filestate.name, str.len });
        }

        try writer.interface.flush();
    }

    fn address(self: Self) !std.Io.net.IpAddress {
        return try std.Io.net.IpAddress.resolve(self.env.io, self.args.ip, self.args.port);
    }

    fn gocStore(self: *Self) !*blob.Store {
        if (self.store == null) {
            if (self.env.log.level(1)) |w|
                try w.print("Creating blob store in '{s}'\n", .{self.args.store_path});
            self.store = blob.Store.init(self.env.a);
            try self.store.?.open(self.args.store_path);
        }
        return &self.store.?;
    }
};
