const std = @import("std");
const cli = @import("cli.zig");
const rubr = @import("rubr.zig");
const tree = @import("tree.zig");
const prot = @import("prot.zig");
const crypto = @import("crypto.zig");
const srvr = @import("srvr.zig");
const clnt = @import("clnt.zig");
const cpy = @import("cpy.zig");
const store = @import("store.zig");
const Env = @import("Env.zig");

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

        var filestore = store.Store.init(self.env.a);
        defer filestore.deinit();

        var cb = struct {
            env: Env,
            replicate: *const prot.Replicate,
            filestore: *store.Store,
            wb: [1024]u8 = undefined,
            ib: [1024]u8 = undefined,
            rb: [1024]u8 = undefined,
            pipe: rubr.pipe.Pipe = undefined,
            writer_thread: std.Thread = undefined,
            reader_thread: std.Thread = undefined,

            fn init(cb: *@This()) !void {
                cb.pipe = rubr.pipe.Pipe.init(&cb.wb, &cb.ib, &cb.rb);
                cb.writer_thread = try std.Thread.spawn(.{}, writer, .{cb});
                cb.reader_thread = try std.Thread.spawn(.{}, reader, .{cb});
            }
            fn deinit(cb: *@This()) void {
                cb.pipe.deinit();
                cb.writer_thread.join();
                cb.reader_thread.join();
            }

            fn writer(cb: *@This()) !void {
                const tw = rubr.comm.TreeWriter{ .out = &cb.pipe.writer };

                try tw.writeComposite(cb.replicate.*, prot.Replicate.Id);
            }
            fn reader(cb: *@This()) !void {
                var tr = rubr.comm.TreeReader{ .in = &cb.pipe.reader };

                var aa = std.heap.ArenaAllocator.init(cb.env.a);
                defer aa.deinit();

                var rep = prot.Replicate.init(aa.allocator());
                defer rep.deinit();
                if (!try tr.readComposite(&rep, prot.Replicate.Id))
                    return Error.ExpectedReplicate;

                var missing = prot.Missing.init(aa.allocator());
                defer missing.deinit();
                for (rep.files.items) |file| {
                    const checksum = file.checksum orelse return Error.ExpectedChecksum;
                    if (cb.filestore.hasFile(checksum)) {
                        std.debug.print("Found '{s}' in store\n", .{file.name});
                    } else {
                        try missing.filenames.append(missing.a, try file.filename(missing.a));
                    }
                }

                if (cb.env.log.level(1)) |w| {
                    var root = rubr.naft.Node.init(w);
                    missing.write(&root);
                }
            }
        }{ .env = self.env, .replicate = &replicate, .filestore = &filestore };
        defer cb.deinit();
        try cb.init();
    }

    fn runServer(self: *Self) !void {
        const addr = try self.address();
        if (self.env.log.level(1)) |w|
            try w.print("Creating server on {f}\n", .{addr});
        var server = try addr.listen(self.env.io, .{});
        defer server.deinit(self.env.io);

        while (true) {
            if (self.env.log.level(1)) |w|
                try w.print("Waiting for connection...\n", .{});

            var connection = try server.accept(self.env.io);
            defer connection.close(self.env.io);
            if (self.env.log.level(1)) |w|
                try w.print("Received connection {f}\n", .{connection.socket.address});

            var session = srvr.Session{ .env = self.env };
            session.init(connection);
            defer session.deinit();

            try session.execute();

            // break;
        }
    }

    fn runClient(self: *Self) !void {
        const addr = try self.address();
        if (self.env.log.level(1)) |w|
            try w.print("Connecting to {f}\n", .{addr});
        var stream = try addr.connect(self.env.io, .{ .mode = .stream });
        defer stream.close(self.env.io);

        var src_dir = try std.fs.openDirAbsolute(self.src orelse return Error.ExpectedSrc, .{});
        defer src_dir.close();

        var session = clnt.Session{
            .env = self.env,
            .base = self.base,
            .src_dir = src_dir,
        };
        session.init(stream);
        defer session.deinit();

        session.setArgv(self.extra);

        try session.execute();
    }

    fn address(self: Self) !std.Io.net.IpAddress {
        const ip = self.ip orelse return Error.ExpectedIp;
        const port = self.port orelse return Error.ExpectedPort;
        return try std.Io.net.IpAddress.resolve(self.env.io, ip, port);
    }
};
