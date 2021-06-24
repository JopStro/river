// This file is part of river, a dynamic tiling wayland compositor.
//
// Copyright 2020 The River Developers
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.

const std = @import("std");
const assert = std.debug.assert;
const os = std.os;

const wlr = @import("wlroots");

// River requires wlroots 0.14
comptime {
    assert(wlr.version.major == 0);
    assert(wlr.version.minor == 14);
}

const build_options = @import("build_options");

const c = @import("c.zig");
const util = @import("util.zig");

const Server = @import("Server.zig");

pub var server: Server = undefined;

pub var level: std.log.Level = switch (std.builtin.mode) {
    .Debug => .debug,
    .ReleaseSafe => .notice,
    .ReleaseFast => .err,
    .ReleaseSmall => .emerg,
};

const usage: []const u8 =
    \\Usage: river [options]
    \\
    \\  -h            Print this help message and exit.
    \\  -c <command>  Run `sh -c <command>` on startup.
    \\  -l <level>    Set the log level to a value from 0 to 7.
    \\
;

pub fn main() anyerror!void {
    var startup_command: ?[:0]const u8 = null;
    {
        var it = std.process.args();
        // Skip our name
        _ = it.nextPosix();
        while (it.nextPosix()) |arg| {
            if (std.mem.eql(u8, arg, "-h")) {
                const stdout = std.io.getStdOut().writer();
                try stdout.print(usage, .{});
                os.exit(0);
            } else if (std.mem.eql(u8, arg, "-c")) {
                if (it.nextPosix()) |command| {
                    // If the user used '-c' multiple times the variable
                    // already holds a path and needs to be freed.
                    if (startup_command) |cmd| util.gpa.free(cmd);
                    startup_command = try util.gpa.dupeZ(u8, command);
                } else {
                    printErrorExit("Error: flag '-c' requires exactly one argument", .{});
                }
            } else if (std.mem.eql(u8, arg, "-l")) {
                if (it.nextPosix()) |level_str| {
                    const log_level = std.fmt.parseInt(u3, level_str, 10) catch
                        printErrorExit("Error: invalid log level '{s}'", .{level_str});
                    level = @intToEnum(std.log.Level, log_level);
                } else {
                    printErrorExit("Error: flag '-l' requires exactly one argument", .{});
                }
            } else {
                const stderr = std.io.getStdErr().writer();
                try stderr.print(usage, .{});
                os.exit(1);
            }
        }
    }

    wlr.log.init(switch (level) {
        .debug => .debug,
        .notice, .info => .info,
        .warn, .err, .crit, .alert, .emerg => .err,
    });

    if (startup_command == null) {
        if (try getStartupCommand()) |path| startup_command = path;
    }

    std.log.info("initializing server", .{});
    try server.init();
    defer server.deinit();

    try server.start();

    // Run the child in a new process group so that we can send SIGTERM to all
    // descendants on exit.
    const child_pgid = if (startup_command) |cmd| blk: {
        std.log.info("running startup command '{s}'", .{cmd});
        const child_args = [_:null]?[*:0]const u8{ "/bin/sh", "-c", cmd, null };
        const pid = try os.fork();
        if (pid == 0) {
            if (c.setsid() < 0) unreachable;
            if (os.system.sigprocmask(os.SIG_SETMASK, &os.empty_sigset, null) < 0) unreachable;
            os.execveZ("/bin/sh", &child_args, std.c.environ) catch c._exit(1);
        }
        util.gpa.free(cmd);
        // Since the child has called setsid, the pid is the pgid
        break :blk pid;
    } else null;
    defer if (child_pgid) |pgid|
        os.kill(-pgid, os.SIGTERM) catch |e| std.log.err("failed to kill startup process: {s}", .{e});

    std.log.info("running server", .{});

    server.wl_server.run();

    std.log.info("shutting down", .{});
}

fn printErrorExit(comptime format: []const u8, args: anytype) noreturn {
    const stderr = std.io.getStdErr().writer();
    stderr.print(format ++ "\n", args) catch os.exit(1);
    os.exit(1);
}

fn testConfigPath(comptime fmt: []const u8, args: anytype) std.fmt.AllocPrintError!?[:0]const u8 {
    const path = try std.fmt.allocPrintZ(util.gpa, fmt, args);
    os.access(path, os.X_OK) catch {
        util.gpa.free(path);
        return null;
    };
    return path;
}

fn getStartupCommand() std.fmt.AllocPrintError!?[:0]const u8 {
    if (os.getenv("XDG_CONFIG_HOME")) |xdg_config_home| {
        if (try testConfigPath("{s}/river/init", .{xdg_config_home})) |path| {
            return path;
        }
    } else if (os.getenv("HOME")) |home| {
        if (try testConfigPath("{s}/.config/river/init", .{home})) |path| {
            return path;
        }
    }
    if (try testConfigPath(build_options.default_config_path, .{})) |path| {
        return path;
    }
    return null;
}

pub fn log(
    comptime message_level: std.log.Level,
    comptime scope: @TypeOf(.foobar),
    comptime format: []const u8,
    args: anytype,
) void {
    if (@enumToInt(message_level) <= @enumToInt(level)) {
        // Don't store/log messages in release small mode to save space
        if (std.builtin.mode != .ReleaseSmall) {
            const stderr = std.io.getStdErr().writer();
            stderr.print(@tagName(message_level) ++ ": (" ++ @tagName(scope) ++ ") " ++
                format ++ "\n", args) catch return;
        }
    }
}
