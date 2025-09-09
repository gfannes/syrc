const std = @import("std");
const rubr = @import("rubr.zig");

pub const Error = error{
    ReceivedSomethingElse,
    CouldNotReadOk,
    CouldNotReadKo,
};

pub const Io = struct {
    const Self = @This();
    const TreeReader = rubr.comm.TreeReader(*std.Io.Reader);
    const TreeWriter = rubr.comm.TreeWriter(*std.Io.Writer);

    readbuf: [1024]u8 = undefined,
    writebuf: [1024]u8 = undefined,

    reader: std.net.Stream.Reader = undefined,
    writer: std.net.Stream.Writer = undefined,

    tr: TreeReader = undefined,
    tw: TreeWriter = undefined,

    pub fn init(self: *Self, stream: std.net.Stream) void {
        self.reader = stream.reader(&self.readbuf);
        self.writer = stream.writer(&self.writebuf);
        self.tr = TreeReader{ .in = self.reader.interface() };
        self.tw = TreeWriter{ .out = &self.writer.interface };
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
