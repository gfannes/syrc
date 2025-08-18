const std = @import("std");
const prot = @import("prot.zig");
const rubr = @import("rubr.zig");

pub const Error = error{
    ExpectedHello,
    ExpectedReplicate,
    ExpectedRun,
    ExpectedBye,
    EmptyBaseFolder,
    UnknownId,
};

pub const Session = struct {
    const Self = @This();
    const TreeReader = rubr.comm.TreeReader(std.net.Stream);

    a: std.mem.Allocator,
    log: *const rubr.log.Log,
    stream: std.net.Stream,
    tr: TreeReader,

    pub fn init(a: std.mem.Allocator, log: *const rubr.log.Log, stream: std.net.Stream) Self {
        return Self{ .a = a, .log = log, .stream = stream, .tr = TreeReader{ .in = stream } };
    }
    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn run(self: *Self) !void {
        var quit = false;
        while (!quit) {
            var aa = std.heap.ArenaAllocator.init(self.a);
            defer aa.deinit();

            const a = aa.allocator();

            const header = try self.tr.readHeader();
            switch (header.id) {
                prot.Hello.Id => {
                    const T = prot.Hello;
                    var msg: T = undefined;
                    if (!try self.tr.readComposite(&msg, T.Id, {}))
                        return Error.ExpectedHello;
                    try self.printMessage(msg);
                },
                prot.Replicate.Id => {
                    const T = prot.Replicate;
                    var msg = T.init(a);
                    defer msg.deinit();
                    if (!try self.tr.readComposite(&msg, T.Id, a))
                        return Error.ExpectedReplicate;
                    try self.printMessage(msg);

                    try self.doReplicate(msg);
                },
                prot.Run.Id => {
                    const T = prot.Run;
                    var msg = T.init(a);
                    defer msg.deinit();
                    if (!try self.tr.readComposite(&msg, T.Id, a))
                        return Error.ExpectedRun;
                    try self.printMessage(msg);
                },
                prot.Bye.Id => {
                    const T = prot.Bye;
                    var msg: T = undefined;
                    if (!try self.tr.readComposite(&msg, T.Id, {}))
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

    fn doReplicate(self: *Self, replicate: prot.Replicate) !void {
        if (replicate.base.len == 0)
            return Error.EmptyBaseFolder;

        if (self.log.level(1)) |w|
            try w.print("Deleting {s}, if present\n", .{replicate.base});
        std.fs.cwd().deleteTree(replicate.base) catch {};

        if (self.log.level(1)) |w|
            try w.print("Creating base {s}\n", .{replicate.base});
        var base = try std.fs.cwd().makeOpenPath(replicate.base, .{});
        defer base.close();

        for (replicate.files.items) |file| {
            if (file.content) |content| {
                // &todo: Set file attributes
                if (file.path) |path| {
                    if (self.log.level(1)) |w|
                        try w.print("Creating path {s}\n", .{path});
                    // &perf: Keep track of already opened folders, without exceeding the file handle quota
                    var dir = try base.makeOpenPath(path, .{});
                    defer dir.close();
                    try dir.writeFile(.{ .sub_path = file.name, .data = content });
                } else {
                    try base.writeFile(.{ .sub_path = file.name, .data = content });
                }
            }
        }
    }

    fn printMessage(self: Self, msg: anytype) !void {
        if (self.log.level(1)) |w| {
            try w.print("\nReceived message:\n", .{});
            var root = rubr.naft.Node.init(w);
            msg.write(&root);
        }
    }
};
