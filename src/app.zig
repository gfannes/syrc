const std = @import("std");
const cli = @import("cli.zig");
const rubr = @import("rubr.zig");
const tree = @import("tree.zig");

pub const Error = error{
    ExpectedIp,
    ExpectedPort,
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

        var walker = rubr.walker.Walker.init(self.a);
        defer walker.deinit();

        const CollectFileStates = struct {
            const My = @This();
            const FileStates = std.ArrayList(tree.FileState);

            a: std.mem.Allocator,
            total_size: u64 = 0,
            file_states: FileStates,

            fn init(a: std.mem.Allocator) My {
                return My{ .a = a, .file_states = FileStates.init(a) };
            }
            fn deinit(my: *My) void {
                for (my.file_states.items) |item| {
                    my.a.free(item.path);
                    if (item.data) |data|
                        my.a.free(data);
                }
                my.file_states.deinit();
            }

            pub fn call(my: *My, dir: std.fs.Dir, path: []const u8, offset: ?rubr.walker.Offsets, kind: rubr.walker.Kind) !void {
                _ = offset;

                if (kind == rubr.walker.Kind.File) {
                    const file = try dir.openFile(path, .{});
                    defer file.close();

                    const stat = try file.stat();
                    const my_size = stat.size;
                    my.total_size += my_size;
                    std.debug.print("Path: {s}, my size: {}, total_size: {}\n", .{ path, my_size, my.total_size });

                    const r = file.reader();

                    const content = try r.readAllAlloc(my.a, my_size);

                    const file_state = tree.FileState{
                        .path = try my.a.dupe(u8, path),
                        .data = content,
                    };
                    try my.file_states.append(file_state);
                }
            }
        };

        var cb = CollectFileStates.init(self.a);
        defer cb.deinit();

        try walker.walk(std.fs.cwd(), &cb);
    }
};
