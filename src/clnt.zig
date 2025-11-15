// &todo: Rename into Source

const std = @import("std");
const prot = @import("prot.zig");
const comm = @import("comm.zig");
const tree = @import("tree.zig");
const rubr = @import("rubr.zig");
const Env = rubr.Env;

pub const Error = error{
    ExpectedHello,
    ExpectedSync,
    ExpectedRun,
    ExpectedBye,
    ExpectedStatusOk,
    ExpectedContent,
    EmptyBaseFolder,
    BaseAlreadySet,
    BaseNotSet,
    UnknownId,
    PeerGaveUp,
    IXOutOfBound,
};

pub const Session = struct {
    const Self = @This();

    env: Env,
    address: std.Io.net.IpAddress,
    subdir: []const u8,
    reset: bool,
    cleanup: bool,
    src: []const u8,

    maybe_cmd: ?[]const u8 = null,
    args: []const []const u8 = &.{},
    stream: ?std.Io.net.Stream = null,
    cio: comm.Io = undefined,

    pub fn init(self: *Self) !void {
        if (self.env.log.level(1)) |w|
            try w.print("Connecting to {f}\n", .{self.address});
        self.stream = try self.address.connect(self.env.io, .{ .mode = .stream });
        self.cio.init(self.env.io, self.stream.?);
    }
    pub fn deinit(self: *Self) void {
        if (self.stream) |*stream|
            stream.close(self.env.io);
    }

    pub fn setArgv(self: *Self, argv: []const []const u8) void {
        if (argv.len < 1)
            return;
        self.maybe_cmd = argv[0];
        self.args = argv[1..];
    }

    pub fn execute(self: *Self) !void {
        var bye = prot.Bye.init(self.env.a);
        defer bye.deinit();

        try self.cio.send(prot.Hello{ .role = .Client, .status = .Pending });

        {
            var hello: prot.Hello = undefined;
            if (try self.cio.receive2(&hello, &bye)) {
                if (self.env.log.level(1)) |w|
                    prot.printMessage(hello, w, null);
                if (hello.status != .Ok) {
                    try bye.setReason("Expected status Ok, not {}", .{hello.status});
                    try self.cio.send(bye);
                    return Error.ExpectedStatusOk;
                }
            } else {
                if (self.env.log.level(1)) |w|
                    prot.printMessage(bye, w, null);
                return Error.PeerGaveUp;
            }
        }

        {
            var sync = prot.Sync.init(self.env.a);
            defer sync.deinit();

            var src_dir = try std.fs.openDirAbsolute(self.src, .{});
            defer src_dir.close();

            sync.subdir = try sync.a.dupe(u8, self.subdir);
            sync.reset = self.reset;
            sync.cleanup = self.cleanup;
            if (self.env.log.level(1)) |w|
                prot.printMessage(sync, w, null);
            try self.cio.send(sync);

            var filestates = try tree.collectFileStates(self.env, src_dir);
            defer {
                for (filestates.items) |*fs|
                    fs.deinit();
                filestates.deinit(self.env.a);
            }

            {
                for (filestates.items, 0..) |fs, count| {
                    if (self.env.log.level(1)) |w|
                        prot.printMessage(fs, w, count);

                    try self.cio.send(fs);
                }

                // Indicate we sent all FileStates
                const sentinel = prot.FileState.init(self.env.a);
                try self.cio.send(sentinel);

                if (self.env.log.level(1)) |w| {
                    try w.print("Sent all FileStates\n", .{});
                    try w.flush();
                }
            }

            var missings = std.ArrayList(usize){};
            defer missings.deinit(self.env.a);
            for (0..std.math.maxInt(usize)) |count| {
                var missing = prot.Missing{};
                if (try self.cio.receive(&missing)) {
                    if (self.env.log.level(1)) |w|
                        prot.printMessage(missing, w, count);

                    if (missing.id) |id| {
                        try missings.append(self.env.a, id);
                    } else {
                        // Peer has all the data
                        break;
                    }
                }
            }
            if (self.env.log.level(1)) |w| {
                try w.print("Server misses {} files\n", .{missings.items.len});
                try w.flush();
            }

            for (missings.items, 0..) |id, count| {
                var content = prot.Content{ .a = null, .id = id };
                if (id >= filestates.items.len)
                    return Error.IXOutOfBound;
                const file = filestates.items[id];
                content.str = file.content orelse return Error.ExpectedContent;
                if (self.env.log.level(1)) |w|
                    prot.printMessage(content, w, count);

                try self.cio.send(content);
            }
            try self.cio.send(prot.Content{ .a = null });
            if (self.env.log.level(1)) |w| {
                try w.print("Sent all missing Content\n", .{});
                try w.flush();
            }
        }

        if (self.maybe_cmd) |cmd| {
            var run = prot.Run.init(self.env.a);
            defer run.deinit();
            run.cmd = try run.a.dupe(u8, cmd);
            for (self.args) |arg|
                try run.args.append(self.env.a, try run.a.dupe(u8, arg));

            try self.cio.send(run);
            if (self.env.log.level(1)) |w| {
                try w.print("Sent Run command\n", .{});
                try w.flush();
            }

            while (true) {
                var output = prot.Output.init(self.env.a);
                defer output.deinit();
                var done = prot.Done{};
                if (try self.cio.receive2(&output, &done)) {
                    if (self.env.log.level(1)) |w|
                        prot.printMessage(output, w, null);
                } else {
                    if (self.env.log.level(1)) |w|
                        prot.printMessage(done, w, null);
                    break;
                }
            }
        }
        if (self.env.log.level(1)) |w| {
            try w.print("Received all output from Run command\n", .{});
            try w.flush();
        }

        try self.cio.send(bye);
    }
};
