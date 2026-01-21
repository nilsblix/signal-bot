const std = @import("std");
const Allocator = std.mem.Allocator;

const Signal = @import("Signal.zig");
const Config = @import("Config.zig");

const lang = @import("lang.zig");
const Context = lang.Context;
const Expression = lang.Expression;
const Parser = @import("Parser.zig");

const builtins = @import("builtins.zig");

parsed: std.json.Parsed(Config),
signal: Signal,

const Bot = @This();

pub fn init(alloc: Allocator, config_path: []const u8) !Bot {
    var f = try std.fs.cwd().openFile(config_path, .{});
    defer f.close();

    var reader_buf: [4096]u8 = undefined;
    var reader = f.reader(&reader_buf);

    const n = try reader.getSize();
    const json = try reader.interface.readAlloc(alloc, n);
    defer alloc.free(json);

    const parsed = try Config.parse(alloc, json);

    const c = parsed.value;
    const signal = try Signal.init(alloc, c.target, c.event_uri, c.rpc_uri);

    return Bot{
        .parsed = parsed,
        .signal = signal,
    };
}

pub fn deinit(self: *Bot) void {
    self.parsed.deinit();
    self.signal.deinit();
}

const echo = lang.FnCall.Impl{
    .@"fn" = struct {
        pub fn call(_: ?*anyopaque, ctx: *Context, args: []const Expression) lang.Error!Expression {
            var buf = std.ArrayList(u8).empty;
            defer buf.deinit(ctx.scratch);

            for (args) |arg| {
                const val = try ctx.eval(arg);
                switch (val) {
                    .int => |d| {
                        const s = try std.fmt.allocPrint(ctx.scratch, "{d}", .{d});
                        try buf.appendSlice(ctx.scratch, s);
                    },
                    .string => |s| {
                        try buf.appendSlice(ctx.scratch, s);
                    },
                    .void, .@"var", .fn_call => {
                        return error.InvalidCast;
                    },
                }
            }

            ctx.signal.sendMessage(ctx.scratch, buf.items) catch return error.SignalError;
            return .void;
        }
    }.call,
};

const username_of_dn = lang.FnCall.Impl{
    .@"fn" = struct {
        pub fn call(_: ?*anyopaque, ctx: *Context, args: []const Expression) lang.Error!Expression {
            if (args.len != 1) return error.InvalidArgumentsCount;

            const val = try ctx.eval(args[0]);
            const da = try val.asString();

            const user = ctx.config.userFromDisplayName(da) orelse {
                const fmt = std.fmt.allocPrint(ctx.scratch, "error: no user with the display name {s} exists", .{da}) catch
                                    "error: no user with such display name exists";
                ctx.signal.sendMessage(ctx.scratch, fmt) catch return error.SignalError;
                return .void;
            };

            return Expression{ .string = user.username };
        }
    }.call,
};

const all = builtins.all ++ [_]builtins.Builtin{
    .{
        .name = "echo",
        .impl = echo,
    },
    .{
        .name = "username_of_dn",
        .impl = username_of_dn,
    },
};

fn config(self: *const Bot) Config {
    return self.parsed.value;
}

pub fn run(self: *Bot, alloc: Allocator) !void {
    const conf = self.config();

    var arena_instance = std.heap.ArenaAllocator.init(alloc);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    var scratch_instance = std.heap.ArenaAllocator.init(alloc);
    defer scratch_instance.deinit();
    const scratch = scratch_instance.allocator();

    while (true) {
        while (!arena_instance.reset(.free_all)) {
            std.log.warn("arena_instance did not reset correctly. trying again...\n", .{});
        }

        while (!scratch_instance.reset(.free_all)) {
            std.log.warn("arena_instance did not reset correctly. trying again...\n", .{});
        }

        var parsed = self.signal.receive(alloc) catch |e| {
            std.log.err("error while receiving message: {}\n", .{e});
            continue;
        };
        defer parsed.deinit();

        const message = parsed.value;
        const cmd = cmd: {
            const text = message.textMessage() orelse continue;
            if (!std.mem.startsWith(u8, text, conf.cmd_prefix)) continue;

            break :cmd text[conf.cmd_prefix.len..];
        };

        if (!conf.isTrustedMessage(message)) continue;

        if (message.groupInfo()) |group| {
            _ = group;
            self.handleGroupMessage(arena, scratch, message, cmd) catch |e| {
                const fmt = std.fmt.allocPrint(scratch, "error while evaluating arbitrary: {}", .{e}) catch
                    "error while evaluating arbitrary";

                self.signal.sendMessage(scratch, fmt) catch {
                    std.log.err("{s}\n", .{fmt});
                };
            };
        }
    }
}

fn handleGroupMessage(
    self: *Bot,
    arena: Allocator,
    scratch: Allocator,
    message: Signal.Message,
    cmd: []const u8,
) !void {
    const conf = self.config();
    const author = conf.userFromNumber(message.sourceSafeNumber()) orelse return;

    if (author.trust < conf.minimum.to_interact) {
        return;
    }

    var parser = Parser.init(null, cmd);
    const tok = parser.nextToken();

    switch (tok.kind) {
        .symbol => {
            const rest = cmd[parser.cur..];
            if (std.mem.eql(u8, tok.text, "eval") and author.trust >= conf.minimum.to_eval_arbitrary) {
                try self.evalArbitrary(arena, scratch, rest, author, &.{});
                return;
            }

            try self.evalCommand(arena, scratch, message, tok.text, rest);
        },
        .num => {
            try self.signal.sendMessage(scratch, "error: command cannot start with a number");
        },
        .string => {
            try self.signal.sendMessage(scratch, "error: command cannot start with a string literal");
        },
        .oparen => {
            try self.signal.sendMessage(scratch, "error: command cannot start with a '('");
        },
        .cparen => {
            try self.signal.sendMessage(scratch, "error: command cannot start with a ')'");
        },
        .comma => {
            try self.signal.sendMessage(scratch, "error: command cannot start with a ','");
        },
        .end => {
            try self.signal.sendMessage(scratch, "error: no command was specified");
        },
        .illegal => {
            const fmt = std.fmt.allocPrint(scratch, "error: found illegal token: {s}", .{tok.text}) catch
                        "error: found illegal token";
            try self.signal.sendMessage(scratch, fmt);
        },
    }
}

const Command = struct {
    name: []const u8,
    /// Arguments to the command are denoted with the runtime known vars
    /// __first, __second, __third...
    script: []const u8,
};

const commands = [_]Command{
    .{
        .name = "whoami",
        .script = "echo(author)",
    },
    .{
        .name = "at",
        .script = "echo('Yo ', username_of_dn(__first))",
    },
    .{
        .name = "test",
        .script = "echo(__first)"
    },
};

const UserArg = union(enum) {
    string: []const u8,
    int: u64,

    fn expression(self: UserArg) Expression {
        return switch (self) {
            .string => |s| .{ .string = s },
            .int => |d| .{ .int = d },
        };
    }

    fn name(scratch: Allocator, index: usize) !?[]const u8 {
        const n: []const u8 = switch (index) {
            0 => "first",
            1 => "second",
            2 => "third",
            3 => "fourth",
            4 => "fifth",
            5 => "sixth",
            6 => "seventh",
            7 => "eighth",
            8 => "ninth",
            9 => "tenth",
            else => return null,
        };

        return try std.fmt.allocPrint(scratch, "__{s}", .{n});
    }
};

fn evalCommand(
    self: *Bot,
    arena: Allocator,
    scratch: Allocator,
    message: Signal.Message,
    cmd_name: []const u8,
    rest: []const u8,
) !void {
    const conf = self.config();
    const author = conf.userFromNumber(message.sourceSafeNumber()) orelse return;

    for (commands) |command| {
        if (std.mem.eql(u8, command.name, cmd_name)) {
            var args_it = std.mem.tokenizeAny(u8, rest, &std.ascii.whitespace);
            var args = std.ArrayList(UserArg).empty;
            defer args.deinit(scratch);

            while (args_it.next()) |slice| {
                var arg_parser = Parser.init(null, slice);
                const tok = arg_parser.nextToken();
                switch (tok.kind) {
                    .num => {
                        const int = std.fmt.parseInt(u64, tok.text, 10) catch |e| {
                            const fmt = std.fmt.allocPrint(scratch, "error: could not parse int argument `{s}`: {}", .{tok.text, e}) catch
                                        "error: could not parse int argument";
                            try self.signal.sendMessage(scratch, fmt);
                            return;
                        };

                        try args.append(scratch, .{ .int = int });
                    },
                    .string => {
                        try args.append(scratch, .{ .string = tok.text });
                    },
                    .symbol => {
                        try self.signal.sendMessage(scratch, "error: argument cannot be a variable");
                    },
                    .oparen => {
                    },
                    .cparen => {
                        try self.signal.sendMessage(scratch, "error: argument cannot start with a ')'");
                    },
                    .comma => {
                        try self.signal.sendMessage(scratch, "error: argument cannot start with a ','");
                    },
                    .illegal => {
                        const fmt = std.fmt.allocPrint(scratch, "error: found illegal token: {s}", .{tok.text}) catch
                                    "error: found illegal token";
                        try self.signal.sendMessage(scratch, fmt);
                    },
                    .end => break,
                }
            }

            std.debug.print("args.items = {any}\n", .{args.items});
            try self.evalArbitrary(arena, scratch, command.script, author, args.items[0..]);
            return;
        }
    }

    const fmt = std.fmt.allocPrint(scratch, "error: unknown command: {s}", .{cmd_name}) catch
                "error: unknown command";
    try self.signal.sendMessage(scratch, fmt);
}

fn evalArbitrary(
    self: *Bot,
    arena: Allocator,
    scratch: Allocator,
    script: []const u8,
    author: Config.User,
    user_args: []const UserArg,
) !void {
    std.debug.print("eval arbitrary script: `{s}`\n", .{script});

    const conf = self.config();
    var context = Context.init(arena, scratch, &self.signal, &conf);
    for (all) |builtin| {
        try context.fns.put(builtin.name, builtin.impl);
    }

    try context.vars.put("author", .{ .string = author.display_name });
    try context.vars.put("username", .{ .string = author.username });

    for (user_args, 0..) |user_arg, i| {
        const name = try UserArg.name(scratch, i) orelse {
            try self.signal.sendMessage(scratch, "error: more arguments than the max allowed arguments were specified");
            return;
        };
        std.debug.print("name = `{s}`\n", .{name});
        try context.vars.put(name, user_arg.expression());
    }

    var parser = Parser.init(null, script);
    const res = try parser.nextExpression(arena);
    switch (res) {
        .end => return,
        .err => |err| {
            const fmt = try err.format(scratch);
            try self.signal.sendMessage(scratch, fmt);
        },
        .expr => |expr| {
            _ = context.eval(expr) catch |e| switch (e) {
                error.SignalError, error.OutOfMemory => return,
                error.InvalidCast => {
                    try self.signal.sendMessage(scratch, "error: Found invalid type-cast");
                },
                error.UnknownVariable => {
                    try self.signal.sendMessage(scratch, "error: Found unknown variable");
                },
                error.UnknownFn => {
                    try self.signal.sendMessage(scratch, "error: Found unknown function");
                },
                error.InvalidArgumentsCount => {
                    try self.signal.sendMessage(scratch, "error: Invalid argument count");
                },
                error.InvalidArgumentName => {
                    try self.signal.sendMessage(scratch, "error: Invalid argument name");
                },
                error.InvalidArgumentValue => {
                    try self.signal.sendMessage(scratch, "error: Invalid argument value");
                },
                error.Shadowing => {
                    try self.signal.sendMessage(scratch, "error: Variable shadows outside variable");
                },
            };
        },
    }
}
