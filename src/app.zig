const std = @import("std");
const cli = @import("cli.zig");
const rubr = @import("rubr.zig");
const tree = @import("tree.zig");
const crypto = @import("crypto.zig");
const sedes = @import("sedes.zig");

pub const Error = error{
    ExpectedIp,
    ExpectedPort,
    ExpectedOffsets,
    ExpectedReplicate,
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

        const CollectFileStates = struct {
            const My = @This();
            const FileStates = std.ArrayList(tree.FileState);

            a: std.mem.Allocator,
            file_states: FileStates,
            walker: rubr.walker.Walker,
            total_size: u64 = 0,

            fn init(a: std.mem.Allocator) My {
                return My{ .a = a, .file_states = FileStates.init(a), .walker = rubr.walker.Walker.init(a) };
            }
            fn deinit(my: *My) void {
                for (my.file_states.items) |item| {
                    my.a.free(item.path);
                    if (item.data) |data|
                        my.a.free(data);
                }
                my.file_states.deinit();
                my.walker.deinit();
            }

            fn collect(my: *My) !void {
                try my.walker.walk(std.fs.cwd(), my);
            }

            pub fn call(my: *My, dir: std.fs.Dir, path: []const u8, maybe_offsets: ?rubr.walker.Offsets, kind: rubr.walker.Kind) !void {
                if (kind == rubr.walker.Kind.File) {
                    const offsets = maybe_offsets orelse return Error.ExpectedOffsets;

                    const file = try dir.openFile(path, .{});
                    defer file.close();

                    const stat = try file.stat();
                    const my_size = stat.size;
                    my.total_size += my_size;
                    std.debug.print("Path: {s}, my size: {}, total_size: {}\n", .{ path, my_size, my.total_size });

                    const r = file.reader();

                    const content = try r.readAllAlloc(my.a, my_size);

                    const file_state = tree.FileState{
                        .path = try my.a.dupe(u8, path[offsets.base..]),
                        .data = content,
                        .checksum = crypto.checksum(content),
                    };
                    try my.file_states.append(file_state);
                }
            }
        };

        var collect_file_states = CollectFileStates.init(self.a);
        defer collect_file_states.deinit();

        try collect_file_states.collect();

        for (collect_file_states.file_states.items) |item| {
            try item.print(self.log);
        }

        const replicate: tree.Replicate = .{ .base = "tmp", .files = collect_file_states.file_states.items };

        {
            const file = try std.fs.cwd().createFile("output.dat", .{});
            defer file.close();

            const tw = sedes.TreeWriter{ .out = file };

            try tw.writeComposite(&replicate);
        }
        {
            const file = try std.fs.cwd().openFile("output.dat", .{});
            defer file.close();

            var tr = sedes.TreeReader{ .in = file };

            var rep: tree.Replicate = undefined;
            var aa = std.heap.ArenaAllocator.init(self.a);
            defer aa.deinit();
            if (!try tr.readComposite(&rep, aa.allocator()))
                return Error.ExpectedReplicate;
        }
    }
};
