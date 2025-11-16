// &todo: Rename into Source

const std = @import("std");
const prot = @import("prot.zig");
const comm = @import("comm.zig");
const blob = @import("blob.zig");
const tree = @import("tree.zig");
const rubr = @import("rubr.zig");
const Env = rubr.Env;

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

    env: Env,
    address: std.Io.net.IpAddress,

    session: comm.Session = undefined,

    pub fn init(self: *Self, folder: []const u8, store: *blob.Store) !void {
        if (self.env.log.level(1)) |w|
            try w.print("Connecting to {f}\n", .{self.address});

        var stream = try self.address.connect(self.env.io, .{ .mode = .stream });
        errdefer stream.close();
        self.session = comm.Session{ .env = self.env, .folder = folder, .store = store };
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
