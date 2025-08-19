const std = @import("std");
const rubr = @import("rubr.zig");

pub const Error = error{
    ReceivedSomethingElse,
    CouldNotReadOk,
    CouldNotReadKo,
};

pub const Io = struct {
    const Self = @This();
    const TreeReader = rubr.comm.TreeReader(std.net.Stream);
    const TreeWriter = rubr.comm.TreeWriter(std.net.Stream);

    tr: TreeReader,
    tw: TreeWriter,

    pub fn init(stream: std.net.Stream) Self {
        return Self{
            .tr = TreeReader{ .in = stream },
            .tw = TreeWriter{ .out = stream },
        };
    }

    pub fn send(self: Self, obj: anytype) !void {
        try self.tw.writeComposite(obj, @TypeOf(obj).Id);
    }

    // Returns true if 'ok' is received, false otherwise
    pub fn receive(self: *Self, ok: anytype) !bool {
        const OkId = @TypeOf(ok.*).Id;

        const header = try self.tr.readHeader();

        if (header.id != OkId)
            return false;

        if (!try self.tr.readComposite(ok, OkId))
            return Error.CouldNotReadOk;

        return true;
    }

    // Returns true if 'ok' is received, false if 'ko' is received, Error otherwise
    pub fn receive2(self: *Self, ok: anytype, ko: anytype) !bool {
        const OkId = @TypeOf(ok.*).Id;
        const KoId = @TypeOf(ko.*).Id;

        const header = try self.tr.readHeader();

        switch (header.id) {
            OkId => {
                if (!try self.tr.readComposite(ok, OkId))
                    return Error.CouldNotReadOk;
                return true;
            },
            KoId => {
                if (!try self.tr.readComposite(ko, KoId))
                    return Error.CouldNotReadKo;
                return false;
            },
            else => {
                std.debug.print("Expected Id {} or {} but received {}\n", .{ OkId, KoId, header.id });
                return Error.ReceivedSomethingElse;
            },
        }
    }
};
