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
    return Bot {
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
        // Allocators must point at the arena instances stored in this Mem.
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
                        std.log.info("{s} reacted with {s} to {s}\n", .{source_dn, r.emoji, r.to.display_name});
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
        try self.rawEval(mem, unprefixed[eval_cmd.len..], author);
    }
}

fn rawEval(self: *Bot, mem: *Mem, script: []const u8, author: Config.User) error{ OutOfMemory, Signal }!void {
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
            try addSpecificBuiltins(&itp, author);

            const ret_expr = itp.eval(expr) catch |err| {
                try mapLangError(self, mem.scratch, err);
                return;
            };

            if (ret_expr != .void) {
                std.log.warn("rawEval: `{s}` was evaluated to a non-void return type: {any}\n", .{script, ret_expr});
            }
        },
    }
}

fn mapLangError(self: *Bot, scratch: Allocator, err: lang.Error) error{OutOfMemory, Signal}!void {
    switch (err) {
        error.ContextRelated => return error.Signal,
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

fn addSpecificBuiltins(itp: *Interpreter, author: Config.User) !void {
    try itp.fns.put("echo", echo);

    try itp.vars.put("author_username", .{ .string = author.username });
    try itp.vars.put("author_dn", .{ .string = author.display_name });
}

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
                    .void, .@"var", .fn_call => return error.InvalidCast,
                }
            }

            itp.ctx.signal.sendMessage(itp.scratch, buf.items) catch return error.ContextRelated;
            return .void;
        }
    }.call,
};
