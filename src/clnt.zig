// &todo: Rename into Source

const std = @import("std");
const prot = @import("prot.zig");
const comm = @import("comm.zig");
const blob = @import("blob.zig");
const rubr = @import("rubr.zig");

pub const Error = error{
    ExpectedHello,
    ExpectedSync,
    ExpectedRun,
    ExpectedBye,
    EmptyBaseFolder,
    BaseAlreadySet,
    BaseNotSet,
    UnknownId,
};

pub const Client = struct {
    const Self = @This();

    env: rubr.Env,
    address: std.Io.net.IpAddress,

    session: comm.Session = undefined,

    pub fn init(self: *Self, folder: []const u8, store: *blob.Store, name: []const u8, suffix: ?[]const u8) !void {
        if (self.env.log.level(1)) |w|
            try rubr.flush.print(w, "Connecting to {f} ... ", .{self.address});

        var stream = try self.address.connect(self.env.io, .{ .mode = .stream });
        errdefer {
            stream.close(self.env.io);
            if (self.env.log.level(1)) |w|
                rubr.flush.print(w, "Failed\n", .{}) catch {};
        }

        if (self.env.log.level(1)) |w|
            try rubr.flush.print(w, "OK\n", .{});
        self.session = comm.Session{ .env = self.env, .base = folder, .store = store, .name = name, .suffix = suffix };
        try self.session.init(stream);
    }
    pub fn deinit(self: *Self) void {
        self.session.deinit();
    }

    pub fn setRunCommand(self: *Self, argv: []const []const u8) void {
        if (argv.len < 1)
            return;
        self.session.maybe_cmd = argv[0];
        self.session.args = argv[1..];
    }
};
