const std = @import("std");
const crypto = @import("crypto.zig");
const prot = @import("prot.zig");
const rubr = @import("rubr.zig");
const Env = rubr.Env;

pub const Error = error{
    ExpectedOffsets,
    ExpectedContent,
    IXOutOfBound,
};

pub const Tree = struct {
    const Self = @This();
    pub const FileStates = std.ArrayList(prot.FileState);

    env: Env,
    filestates: FileStates = .{},

    pub fn deinit(self: *Self) void {
        for (self.filestates.items) |*fs|
            fs.deinit();
        self.filestates.deinit(self.env.a);
    }

    pub fn getContent(self: Self, id: u64) ![]const u8 {
        if (id >= self.filestates.items.len)
            return Error.IXOutOfBound;
        const file = self.filestates.items[id];
        return file.content orelse return Error.ExpectedContent;
    }
};

pub fn collectTree(env: Env, folder: []const u8) !Tree {
    const Collector = struct {
        const My = @This();
        const Buffer = std.ArrayList(u8);

        env: Env,
        dir: std.Io.Dir,
        filestates: *Tree.FileStates,
        walker: rubr.walker.Walker,

        total_size: u64 = 0,
        // If buffer is present, it will be used to read-in content iso FileState.content
        buffer: ?Buffer = null,

        fn deinit(my: *My) void {
            my.walker.deinit();
            if (my.buffer) |*buf|
                buf.deinit(my.env.a);
            my.dir.close(my.env.io);
        }

        fn collect(my: *My) !void {
            if (my.env.log.level(1)) |w| {
                try w.print("Reading Tree...\n", .{});
                try w.flush();
            }
            const start = try std.time.Instant.now();
            try my.walker.walk(my.dir, my);
            const stop = try std.time.Instant.now();
            if (my.env.log.level(1)) |w| {
                try w.print("Read {f}B in {f}s\n", .{ rubr.fmt.iso(my.total_size, false), rubr.fmt.iso(stop.since(start), true) });
                try w.flush();
            }
        }

        pub fn call(my: *My, dirr: std.Io.Dir, path: []const u8, maybe_offsets: ?rubr.walker.Offsets, kind: rubr.walker.Kind) !void {
            if (kind == rubr.walker.Kind.File) {
                const offsets = maybe_offsets orelse return Error.ExpectedOffsets;

                const file = try dirr.openFile(my.env.io, path, .{});
                defer file.close(my.env.io);

                const stat = try file.stat(my.env.io);
                const my_size = stat.size;
                my.total_size += my_size;
                if (my.env.log.level(3)) |w|
                    try w.print("Path: {s}, my size: {}, total_size: {}\n", .{ path, my_size, my.total_size });

                var buffer: [1024]u8 = undefined;
                var r = file.reader(my.env.io, &buffer);

                var filestate = prot.FileState.init(my.env.a);
                if (offsets.name != offsets.base)
                    filestate.path = try my.env.a.dupe(u8, path[offsets.base .. offsets.name - 1]);
                filestate.name = try my.env.a.dupe(u8, path[offsets.name..]);

                // &todo fix execute mode
                filestate.attributes = .{
                    .read = true,
                    .write = !stat.permissions.readOnly(),
                    .execute = false,
                };

                var content: []u8 = &.{};
                if (my.buffer) |*buf| {
                    try buf.resize(my.env.a, my_size);
                    content = buf.items;
                } else {
                    content = try filestate.a.alloc(u8, my_size);
                    filestate.content = content;
                }

                try r.interface.readSliceAll(content);
                filestate.checksum = crypto.checksum(content);

                filestate.id = my.filestates.items.len;
                try my.filestates.append(my.env.a, filestate);
            }
        }
    };

    var res = Tree{ .env = env };

    var collector = Collector{
        .env = env,
        .dir = try std.Io.Dir.openDirAbsolute(env.io, folder, .{}),
        .filestates = &res.filestates,
        .walker = rubr.walker.Walker{ .env = env },
    };
    defer collector.deinit();

    try collector.collect();

    return res;
}
