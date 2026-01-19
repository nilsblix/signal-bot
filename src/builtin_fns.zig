const std = @import("std");
const lang = @import("lang.zig");
const Context = lang.Context;
const Expression = lang.Expression;
const Impl = lang.FnCall.Impl;

pub const Builtin = struct {
    name: []const u8,
    impl: lang.FnCall.Impl,
};

pub const all = [_]Builtin{
    .{ .name = "echo", .impl = echo },
    .{ .name = "if", .impl = @"if" },
    .{ .name = "eql", .impl = eql },
    .{ .name = "let", .impl = let },
    .{ .name = "define", .impl = define },
    .{ .name = "not", .impl = not },
    .{ .name = "and", .impl = @"and" },
    .{ .name = "gt", .impl = gt },
    .{ .name = "gte", .impl = gte },
    .{ .name = "ls", .impl = ls },
    .{ .name = "lse", .impl = lse },
    .{ .name = "repeat", .impl = repeat },
    .{ .name = "add", .impl = add },
    .{ .name = "do", .impl = do },
};

pub const echo = Impl{
    .@"fn" = struct {
        pub fn call(_: ?*anyopaque, ctx: *Context, args: []const Expression) lang.Error!Expression {
            var buf = std.ArrayList(u8).empty;
            defer buf.deinit(ctx.scratch);

            for (args) |arg| {
                // TODO: add support for printings ints.
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
                    }
                }

            }
            std.debug.print("{s}\n", .{buf.items});
            return .void;
        }
    }.call,
};

pub const @"if" = Impl{
    .@"fn" = struct {
        pub fn call(_: ?*anyopaque, ctx: *Context, args: []const Expression) lang.Error!Expression {
            if (args.len != 3) return error.InvalidArgumentsCount;

            const val = try ctx.eval(args[0]);
            const cond = try val.asString();

            if (std.mem.eql(u8, cond, "true")) {
                return try ctx.eval(args[1]);
            } else if (std.mem.eql(u8, cond, "false")) {
                return try ctx.eval(args[2]);
            } else {
                return error.InvalidArgumentValue;
            }
        }
    }.call,
};

pub const eql = Impl{
    .@"fn" = struct {
        pub fn call(_: ?*anyopaque, ctx: *Context, args: []const Expression) lang.Error!Expression {
            if (args.len != 2) return error.InvalidArgumentsCount;

            const a = try ctx.eval(args[0]);
            const b = try ctx.eval(args[1]);

            return .{ .string = if (a.eql(b)) "true" else "false" };
        }
    }.call,
};

pub const let = Impl{
    .@"fn" = struct {
        pub fn call(_: ?*anyopaque, ctx: *Context, args: []const Expression) lang.Error!Expression {
            if (args.len != 2) return error.InvalidArgumentsCount;

            const name = try args[0].asVar();
            const as = try ctx.eval(args[1]);
            try ctx.vars.put(name, as);
            return .void;
        }
    }.call,
};

pub const define = Impl{
    .@"fn" = struct {
        pub fn call(_: ?*anyopaque, ctx: *Context, args: []const Expression) lang.Error!Expression {
            if (args.len != 3) return error.InvalidArgumentsCount;

            const name = try args[0].asVar();

            const inner_args_fn_call = try args[1].asFnCall();

            if (!std.mem.eql(u8, inner_args_fn_call.name, "args")) {
                return error.InvalidArgumentName;
            }

            const inner_args = inner_args_fn_call.args;
            const Payload = struct {
                name: []const u8,
                inner_args: []Expression,
                to_eval: Expression,
            };

            const payload = try ctx.arena.create(Payload);
            payload.* = .{
                .name = name,
                .inner_args = @constCast(inner_args),
                .to_eval = args[2],
            };

            const impl = lang.FnCall.Impl{
                .payload = payload,
                .@"fn" = struct {
                    pub fn call(untyped_payload: ?*anyopaque, called_ctx: *Context, called_args: []const Expression) lang.Error!Expression {
                        const p: *Payload = @ptrCast(@alignCast(untyped_payload.?));
                        if (p.inner_args.len != called_args.len) return error.InvalidArgumentsCount;

                        // We temporarily alias the argument vars as
                        // called_args, and then when we have called the
                        // function we remove them in order to prevent
                        // shadowing. Of course if the tried alias name
                        // already exists we report that as shadowing.
                        for (p.inner_args, 0..) |inner_arg, i| {
                            const @"var" = try inner_arg.asVar();
                            // Earlier I wanted to call this on the outer
                            // ctx as well, but I realized that since fns
                            // and vars are stored as maps, they wouldn't
                            // be copied deeply enough for the scope to
                            // stay the same as in the `define` statement.
                            const gop = try called_ctx.vars.getOrPut(@"var");
                            if (gop.found_existing) return error.Shadowing;

                            gop.value_ptr.* = called_args[i];
                        }

                        const ret = try called_ctx.eval(p.to_eval);

                        for (p.inner_args) |inner_arg| {
                            const @"var" = try inner_arg.asVar();
                            if (!called_ctx.vars.remove(@"var")) {
                                // This should never happen.
                                unreachable;
                            }
                        }

                        return ret;
                    }
                }.call,
            };

            try ctx.fns.put(name, impl);

            return .void;
        }
    }.call,
};

pub const @"and" = Impl{
    .@"fn" = struct {
        pub fn call(_: ?*anyopaque, ctx: *Context, args: []const Expression) lang.Error!Expression {
            if (args.len == 0) return error.InvalidArgumentsCount;

            for (args) |arg| {
                const val = try ctx.eval(arg);
                const cond = try val.asString();
                if (std.mem.eql(u8, cond, "false")) {
                    return .{ .string = "false" };
                } else if (std.mem.eql(u8, cond, "true")) {
                    continue;
                } else {
                    return error.InvalidArgumentValue;
                }
            }

            return .{ .string = "true" };
        }
    }.call,
};

pub const not = Impl{
    .@"fn" = struct {
        pub fn call(_: ?*anyopaque, ctx: *Context, args: []const Expression) lang.Error!Expression {
            if (args.len != 1) return error.InvalidArgumentsCount;

            const val = try ctx.eval(args[0]);
            const cond = try val.asString();

            if (std.mem.eql(u8, cond, "true")) {
                return Expression{ .string = "false" };
            } else if (std.mem.eql(u8, cond, "false")) {
                return Expression{ .string = "true" };
            } else {
                return error.InvalidArgumentValue;
            }
        }
    }.call,
};

const twoTuple = struct {
    pub fn f(ctx: *Context, args: []const Expression) lang.Error!struct { u64, u64 } {
        if (args.len != 2) return error.InvalidArgumentsCount;

        const a = a: {
            const val = try ctx.eval(args[0]);
            break :a try val.asInt();
        };

        const b = b: {
            const val = try ctx.eval(args[1]);
            break :b try val.asInt();
        };

        return .{ a, b };
    }
}.f;

pub const gt = Impl{
    .@"fn" = struct {
        pub fn call(_: ?*anyopaque, ctx: *Context, args: []const Expression) lang.Error!Expression {
            const v = try twoTuple(ctx, args);
            return Expression{ .string = if (v.@"0" > v.@"1") "true" else "false" };
        }
    }.call,
};

pub const gte = Impl{
    .@"fn" = struct {
        pub fn call(_: ?*anyopaque, ctx: *Context, args: []const Expression) lang.Error!Expression {
            const v = try twoTuple(ctx, args);
            return Expression{ .string = if (v.@"0" >= v.@"1") "true" else "false" };
        }
    }.call,
};

pub const ls = Impl{
    .@"fn" = struct {
        pub fn call(_: ?*anyopaque, ctx: *Context, args: []const Expression) lang.Error!Expression {
            const v = try twoTuple(ctx, args);
            return Expression{ .string = if (v.@"0" < v.@"1") "true" else "false" };
        }
    }.call,
};

pub const lse = Impl{
    .@"fn" = struct {
        pub fn call(_: ?*anyopaque, ctx: *Context, args: []const Expression) lang.Error!Expression {
            const v = try twoTuple(ctx, args);
            return Expression{ .string = if (v.@"0" <= v.@"1") "true" else "false" };
        }
    }.call,
};

pub const repeat = Impl{
    .@"fn" = struct {
        pub fn call(_: ?*anyopaque, ctx: *Context, args: []const Expression) lang.Error!Expression {
            if (args.len != 2) return error.InvalidArgumentsCount;

            // This will be cleaned up as ctx.scratch gets cleanup when having
            // evaluated this master expression.
            var buf = std.ArrayList(u8).empty;

            const n = n: {
                const val = try ctx.eval(args[1]);
                break :n try val.asInt();
            };
            for (0..n) |_| {
                const res = try ctx.eval(args[0]);
                const tmp = res.asString();
                if (tmp != error.InvalidCast) {
                    const slice = try tmp;
                    try buf.appendSlice(ctx.scratch, slice);
                }
            }
            if (buf.items.len != 0) {
                return .{ .string = buf.items };
            }

            return .void;
        }
    }.call,
};

pub const add = Impl{
    .@"fn" = struct {
        pub fn call(_: ?*anyopaque, ctx: *Context, args: []const Expression) lang.Error!Expression {
            if (args.len == 0) return error.InvalidArgumentsCount;

            var ret: u64 = 0;
            for (args) |arg| {
                const val = try ctx.eval(arg);
                const int = try val.asInt();
                ret += int;
            }

            return .{ .int = ret };
        }
    }.call,
};

pub const do = Impl{
    .@"fn" = struct {
        pub fn call(_: ?*anyopaque, ctx: *Context, args: []const Expression) lang.Error!Expression {
            for (args) |arg| {
                _ = try ctx.eval(arg);
            }

            return .void;
        }
    }.call,
};
