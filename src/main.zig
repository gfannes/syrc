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

    const s = rubr.profile.Scope.init(env.io, .A, env.stdout);
    defer s.deinit();

    var cfg_loader = cfg.Loader{ .env = env };
    defer cfg_loader.deinit();
    try cfg_loader.load();

    var cli_args = cli.Args{ .env = env };
    cli_args.init();
    try cli_args.parse(init.minimal.args);
    env_inst.log.setLevel(cli_args.verbose);
    if (cfg_loader.aliases) |aliases|
        if (cli_args.update(aliases))
            if (env.log.level(1)) |w|
                try w.print("Found alias for '{s}'\n", .{cli_args.ip});

    if (cli_args.print_help) {
        try cli_args.printHelp();
        return;
    }

    var my_app = app.App.init(
        env,
        cli_args,
    );
    defer my_app.deinit();

    try my_app.run();
}
