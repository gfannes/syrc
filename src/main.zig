const std = @import("std");
const app = @import("app.zig");
const cli = @import("cli.zig");
const cfg = @import("cfg.zig");
const rubr = @import("rubr.zig");
const Env = rubr.Env;

pub fn main(init: std.process.Init) !void {
    var env_inst = Env.Instance{ .environ = init.minimal.environ };
    env_inst.init();
    defer env_inst.deinit();

    var env = env_inst.env();

    const s = rubr.profile.Scope.init(.A, env.stdout);
    defer s.deinit();

    var config = cfg.Config.init(env.a);
    defer config.deinit();
    try config.load();

    var cli_args = cli.Args{ .env = env };
    cli_args.init();
    try cli_args.parse(init.minimal.args);

    if (cli_args.print_help) {
        try cli_args.printHelp();
        return;
    }

    env_inst.log.setLevel(cli_args.verbose);

    var my_app = app.App.init(
        env,
        cli_args,
    );
    defer my_app.deinit();

    try my_app.run();
}
