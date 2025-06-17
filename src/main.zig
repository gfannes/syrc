const std = @import("std");
const app = @import("app.zig");
const cli = @import("cli.zig");
const cfg = @import("cfg.zig");
const rubr = @import("rubr.zig");

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

    if (cli_args.print_help) {
        cli_args.printHelp();
        return;
    }

    var log = rubr.log.Log{};
    log.init();
    defer log.deinit();
    log.setLevel(cli_args.verbose);

    var my_app = app.App.init(a, &log, cli_args.mode, cli_args.ip, cli_args.port);
    defer my_app.deinit();

    try my_app.run();
}
