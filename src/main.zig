const std = @import("std");
const app = @import("app.zig");
const cfg = @import("cfg.zig");
const rubr = @import("rubr.zig");
const Env = rubr.Env;

pub const Error = error{
    ConfigLoadFailed,
};

pub fn main(init: std.process.Init) !void {
    var env_inst = Env.Instance{ .environ = init.minimal.environ };
    env_inst.init();
    defer env_inst.deinit();

    const env = env_inst.env();

    const s = rubr.profile.Scope.init(env.io, .A, env.stdout);
    defer s.deinit();

    var cfg_loader: cfg.Loader = .{};
    try cfg_loader.init(env);
    defer cfg_loader.deinit();
    try cfg_loader.load(init.minimal.args);

    const config = &cfg_loader.config;

    env_inst.log.setLevel(config.verbose);

    if (config.print_help) {
        try cfg_loader.printHelp(env.stdout);
        return;
    }

    var my_app = app.App.init(
        env,
        config,
    );
    defer my_app.deinit();

    try my_app.run();
}
