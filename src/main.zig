const std = @import("std");
const app = @import("app.zig");
const cli = @import("cli.zig");
const cfg = @import("cfg.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const a = gpa.allocator();

    var config = cfg.Config.init(a);
    defer config.deinit();
    try config.load();

    var cli_args = cli.Args.init(a);
    defer cli_args.deinit();
    try cli_args.parse();

    if (cli_args.mode == null)
        cli_args.print_help = true;

    if (cli_args.print_help) {
        cli_args.printHelp();
        return;
    }

    const mode = cli_args.mode orelse unreachable;
    var my_app = app.App.init(a, mode, cli_args.ip, cli_args.port);
    defer my_app.deinit();
}
