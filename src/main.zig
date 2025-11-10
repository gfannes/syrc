const std = @import("std");
const app = @import("app.zig");
const cli = @import("cli.zig");
const cfg = @import("cfg.zig");
const rubr = @import("rubr.zig");
const Env = rubr.Env;

pub fn main() !void {
    const s = rubr.profile.Scope.init(.A);
    defer s.deinit();

    var env_inst = Env.Instance{};
    env_inst.init();
    defer env_inst.deinit();

    var env = env_inst.env();

    var config = cfg.Config.init(env.a);
    defer config.deinit();
    try config.load();

    var cli_args = cli.Args{ .env = env };
    cli_args.init();
    try cli_args.parse();

    if (cli_args.print_help) {
        cli_args.printHelp();
        return;
    }

    env_inst.log.setLevel(cli_args.verbose);

    var my_app = app.App.init(
        env,
        cli_args.mode,
        cli_args.ip,
        cli_args.port,
        cli_args.base,
        cli_args.src,
        cli_args.store_path,
        cli_args.extra.items,
    );
    defer my_app.deinit();

    try my_app.run();
}
