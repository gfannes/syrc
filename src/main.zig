const std = @import("std");
const app = @import("app.zig");
const cli = @import("cli.zig");
const cfg = @import("cfg.zig");
const rubr = @import("rubr.zig");
const Env = @import("Env.zig");

pub fn main() !void {
    const s = rubr.profile.Scope.init(.A);
    defer s.deinit();

    var env_inst = Env.Instance{};
    env_inst.init();
    defer env_inst.deinit();

    const env = env_inst.env();

    var config = cfg.Config.init(env.a);
    defer config.deinit();
    try config.load();

    var cli_args = cli.Args.init(env.a);
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

    var my_app = app.App.init(
        env,
        cli_args.mode,
        cli_args.ip,
        cli_args.port,
        cli_args.base,
        cli_args.src,
        cli_args.store_path.path(),
        cli_args.extra.items,
    );
    defer my_app.deinit();

    try my_app.run();
}
