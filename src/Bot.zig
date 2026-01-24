const std = @import("std");
const Allocator = std.mem.Allocator;

const Signal = @import("Signal.zig");
const Config = @import("Config.zig");
const Parser = @import("Parser.zig");

const Bot = @This();

const lang = @import("lang.zig");
/// We store a temporary ptr to this current instance when we evaluate scripts,
/// to enable added builtin functions to access/modify the current config/signal
/// state.
const Interpreter = lang.Interpreter(Bot);

signal: Signal,
config: Config,

pub fn init(alloc: Allocator, config: Config) anyerror!Bot {
    const signal = try Signal.init(alloc, config.target, config.event_uri, config.rpc_uri);
    return Bot{
        .signal = signal,
        .config = config,
    };
}

pub fn deinit(self: *Bot) void {
    self.signal.deinit();
}

const Mem = struct {
    arena_instance: std.heap.ArenaAllocator,
    arena: Allocator,
    scratch_instance: std.heap.ArenaAllocator,
    scratch: Allocator,

    fn init(self: *Mem, alloc: Allocator) void {
        self.arena_instance = std.heap.ArenaAllocator.init(alloc);
        self.scratch_instance = std.heap.ArenaAllocator.init(alloc);
        self.arena = self.arena_instance.allocator();
        self.scratch = self.scratch_instance.allocator();
    }

    fn deinit(self: *Mem) void {
        self.arena_instance.deinit();
        self.scratch_instance.deinit();
    }

    fn reset(self: *Mem) void {
        _ = self.arena_instance.reset(.free_all);
        _ = self.scratch_instance.reset(.free_all);
    }
};

pub fn run(self: *Bot, alloc: Allocator) error{ InvalidConfig, OutOfMemory, Signal }!void {
    var mem: Mem = undefined;
    mem.init(alloc);
    defer mem.deinit();

    while (true) {
        // We reset the memory after each expression evaluation to not leak
        // memory at all, and to not let state slowly fill up in RAM.
        //
        // TODO: Real long term memory will be lateron stored in some kind of
        // local database.
        mem.reset();

        const parsed = self.signal.receive(alloc) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ListenerError, error.MessageParseError => continue,
        };
        defer parsed.deinit();

        const sanitized = parsed.value.sanitize(self.config) orelse continue;
        switch (sanitized.info) {
            .dm => {
                // TODO: Here we want to eventually add commands/rules into
                // some database, such that users within the same groupchat can
                // "prank" or simply interact with the bot-state, without an
                // admin being involved.
                continue;
            },
            .group => |g| {
                // We assume that our target chat is also a group.
                const target_group_id = switch (self.config.target) {
                    .group => |id| id,
                    .phone, .user => return error.InvalidConfig,
                };
                if (!std.mem.eql(u8, target_group_id, g.groupId)) {
                    // Some other chat has sent us a message. We do not care,
                    // as we are focused on our target chat.
                    continue;
                }

                switch (sanitized.kind) {
                    .reaction => |r| {
                        const source_dn = sanitized.source.display_name;
                        std.log.info("{s} reacted with {s} to {s}\n", .{ source_dn, r.emoji, r.to.display_name });
                    },
                    .text_message => |text| {
                        // Here we can actually parse and evaluate commands
                        // based on user permissions.
                        if (std.mem.startsWith(u8, text, self.config.cmd_prefix)) {
                            const prefix_len = self.config.cmd_prefix.len;
                            try self.interact(&mem, sanitized.source, text[prefix_len..]);
                        }
                    },
                }
            },
        }
    }
}

fn interact(self: *Bot, mem: *Mem, author: Config.User, unprefixed: []const u8) error{ OutOfMemory, Signal }!void {
    const min = self.config.minimum;

    const eval_cmd = "eval";
    if (author.canRawEval(min) and std.mem.startsWith(u8, unprefixed, eval_cmd)) {
        try self.rawEval(mem, unprefixed[eval_cmd.len..], author, &.{});
    }

    const profile_cmd = "profile";
    if (author.canProfile(min) and std.mem.startsWith(u8, unprefixed, profile_cmd)) {
        const to_run = unprefixed[profile_cmd.len..];
        var parser = Parser.init(null, to_run);
        const pos = parser.nextOccurence(self.config.cmd_prefix) orelse {
            const fmt = try std.fmt.allocPrint(mem.scratch, "error: found no command to profile, found: `{s}`", .{to_run});
            self.signal.sendMessage(mem.scratch, fmt) catch return error.Signal;
            return;
        };

        const cmd = to_run[pos + self.config.cmd_prefix.len ..];
        const start = std.time.milliTimestamp();
        try self.interact(mem, author, cmd);
        const end = std.time.milliTimestamp();

        const dt = end - start;
        const fmt = try std.fmt.allocPrint(mem.scratch, "info: command `{s}` took {d} ms", .{ cmd, dt });
        self.signal.sendMessage(mem.scratch, fmt) catch return error.Signal;
        return;
    }

    var parser = Parser.init(null, unprefixed);
    var tok = parser.nextToken();
    if (tok.kind != .symbol) return;

    const cmd = Command.match(tok.text) orelse return;

    var buf = std.ArrayList(lang.Expression).empty;
    while (true) {
        tok = parser.nextToken();
        switch (tok.kind) {
            .symbol => {
                const fmt = try std.fmt.allocPrint(mem.scratch, "error: cannot call command with a non-literal: {s}", .{tok.text});
                self.signal.sendMessage(mem.scratch, fmt) catch return error.Signal;
                return;
            },
            .num => {
                const n = std.fmt.parseInt(u64, tok.text, 10) catch |e| {
                    const fmt = try std.fmt.allocPrint(mem.scratch, "error: could not parse int {s}: {}", .{ tok.text, e });
                    self.signal.sendMessage(mem.scratch, fmt) catch return error.Signal;
                    return;
                };

                try buf.append(mem.scratch, .{ .int = n });
            },
            .string => {
                try buf.append(mem.scratch, .{ .string = tok.text });
            },
            .oparen => {
                self.signal.sendMessage(mem.scratch, "error: command argument cannot be '('") catch return error.Signal;
                return;
            },
            .cparen => {
                self.signal.sendMessage(mem.scratch, "error: command argument cannot be ')'") catch return error.Signal;
                return;
            },
            .comma => {
                self.signal.sendMessage(mem.scratch, "error: command argument cannot be ','") catch return error.Signal;
                return;
            },
            .illegal => {
                const fmt = try std.fmt.allocPrint(mem.scratch, "error: found invalid token: {s}", .{tok.text});
                self.signal.sendMessage(mem.scratch, fmt) catch return error.Signal;
                return;
            },
            .end => break,
        }
    }

    try self.rawEval(mem, cmd.script, author, buf.items[0..]);
}

fn rawEval(self: *Bot, mem: *Mem, script: []const u8, author: Config.User, user_args: []const lang.Expression) error{ OutOfMemory, Signal }!void {
    var parser = Parser.init(null, script);
    const res = try parser.nextExpression(mem.scratch);
    switch (res) {
        .end => {
            self.signal.sendMessage(mem.scratch, "error: found no script to run") catch return error.Signal;
        },
        .err => |err| {
            const fmt = try err.format(mem.scratch);
            self.signal.sendMessage(mem.scratch, fmt) catch return error.Signal;
        },
        .expr => |expr| {
            var itp = Interpreter.init(mem.arena, mem.scratch, self);

            try itp.addBuiltins();
            try addSpecificBuiltins(&itp, author, user_args);

            const ret_expr = itp.eval(expr) catch |err| {
                try mapLangError(self, mem.scratch, err);
                return;
            };

            if (ret_expr != .void) {
                std.log.warn("rawEval: `{s}` was evaluated to a non-void return type: {any}\n", .{ script, ret_expr });
            }
        },
    }
}

fn mapLangError(self: *Bot, scratch: Allocator, err: lang.Error) error{ OutOfMemory, Signal }!void {
    switch (err) {
        error.HostRelated => return error.Signal,
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidCast => {
            self.signal.sendMessage(scratch, "error: found invalid cast") catch return error.Signal;
        },
        error.UnknownVariable => {
            self.signal.sendMessage(scratch, "error: found unknown variable") catch return error.Signal;
        },
        error.UnknownFn => {
            self.signal.sendMessage(scratch, "error: found unknown function") catch return error.Signal;
        },
        error.InvalidArgumentsCount => {
            self.signal.sendMessage(scratch, "error: invalid number of arguments were supplied") catch return error.Signal;
        },
        error.InvalidArgumentName => {
            self.signal.sendMessage(scratch, "error: invalid argument name was found") catch return error.Signal;
        },
        error.InvalidArgumentValue => {
            self.signal.sendMessage(scratch, "error: invalid argument value") catch return error.Signal;
        },
        error.Shadowing => {
            self.signal.sendMessage(scratch, "error: found argument shadowing") catch return error.Signal;
        },
    }
}

fn addSpecificBuiltins(itp: *Interpreter, author: Config.User, user_args: []const lang.Expression) !void {
    try itp.fns.put("echo", echo);

    try itp.vars.put("author_username", .{ .string = author.username });
    try itp.vars.put("author_dn", .{ .string = author.display_name });

    for (user_args, 1..) |arg, i| {
        const name = argumentName(i) orelse {
            std.log.warn("tried to add more than 10 user called arguments...", .{});
            break;
        };
        switch (arg) {
            .void, .variable, .fn_call => continue,
            .string, .int => {
                try itp.vars.put(name, arg);
            },
        }
    }

    var i: usize = user_args.len + 1;
    while (true) : (i += 1) {
        const name = argumentName(i) orelse break;
        try itp.vars.put(name, .void);
    }
}

/// One-indexed.
fn argumentName(i: usize) ?[]const u8 {
    return switch (i) {
        1 => "__fir__",
        2 => "__sec__",
        3 => "__thi__",
        4 => "__fou__",
        5 => "__fif__",
        6 => "__six__",
        7 => "__sev__",
        8 => "__eig__",
        9 => "__nin__",
        10 => "__ten__",
        else => null,
    };
}

const Command = struct {
    name: []const u8,
    script: []const u8,

    /// TODO: Refactor these into a DB, where users can privately dm the bot to
    /// append new commands/rules.
    const all = [_]Command{
        .{ .name = "whoami", .script = "echo(author_dn)" },
        .{ .name = "ping", .script = "echo('pong')" },
        .{ .name = "yo", .script = "echo('Yo what is up ', __fir__, '!!!')" },
        .{ .name = "snygg", .script = "do(let(x, or(__fir__, author_dn)), echo('Är ', x, ' snygg..? ', if(eql(x, 'Isak Fuckhead'), 'Hell no brother...', 'Omg yes girl!!!!!')))" },
    };

    fn match(name: []const u8) ?Command {
        for (all) |c| {
            if (std.mem.eql(u8, c.name, name)) {
                return c;
            }
        }

        return null;
    }
};

const echo = lang.FnCall.Impl(Bot){
    .@"fn" = struct {
        pub fn call(_: ?*anyopaque, itp: *Interpreter, args: []const lang.Expression) lang.Error!lang.Expression {
            var buf = std.ArrayList(u8).empty;

            for (args) |arg| {
                const val = try itp.eval(arg);
                switch (val) {
                    .string => |s| {
                        try buf.appendSlice(itp.scratch, s);
                    },
                    .int => |d| {
                        const n = try std.fmt.allocPrint(itp.scratch, "{d}", .{d});
                        try buf.appendSlice(itp.scratch, n);
                    },
                    .void, .variable, .fn_call => return error.InvalidCast,
                }
            }

            itp.host.signal.sendMessage(itp.scratch, buf.items) catch return error.HostRelated;
            return .void;
        }
    }.call,
};
