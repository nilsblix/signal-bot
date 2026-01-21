const std = @import("std");
const Allocator = std.mem.Allocator;
const Signal = @import("Signal.zig");
const Config = @import("Config.zig");

pub const Error = error{
    ContextRelated,
    OutOfMemory,
    /// Expression could not cast to the wanted type.
    InvalidCast,
    /// Tried to get an unknown variable from Interpreter.vars.
    UnknownVariable,
    /// Tried to get an unknown function implementation from Interpreter.fns.
    UnknownFn,
    /// An incorrect number of arguments were supplied to a function call.
    InvalidArgumentsCount,
    /// Some functions may require that certain arguments are named in a
    /// certain way. Ex: `define(fn, args(...), ...impl...)` might require
    /// that fn's' arguments are wrapped in a function call named `args`.
    InvalidArgumentName,
    /// Some functions require that certain arguments have certain values,
    /// such as `if(cond, then, else)` which require that `cond` evaluates to
    /// either "true" or "false".
    InvalidArgumentValue,
    Shadowing,
};

pub const FnCall = struct {
    pub fn Impl(comptime Context: type) type {
        return struct {
            /// Used to catch some data in a closure-like fashion. Sometimes, ex:
            /// define in builtin_fns.zig, it is necessary to wrap some data to get
            /// certain vars or fns.
            payload: ?*anyopaque = null,
            @"fn": *const fn (payload: ?*anyopaque, ctx: *Interpreter(Context), args: []const Expression) Error!Expression,
        };
    }

    args: []const Expression,
    /// Gets matched to an implementation (of type Impl) during
    /// runtime/evaluation. This makes it possible to define new functions
    /// during evaluation of the script.
    name: []const u8,
};

pub const Expression = union(enum) {
    void,
    int: u64,
    string: []const u8,
    @"var": []const u8,
    fn_call: FnCall,

    pub fn asInt(self: Expression) error{InvalidCast}!u64 {
        return switch (self) {
            .int => |d| d,
            .void, .string, .@"var", .fn_call => error.InvalidCast,
        };
    }

    pub fn asString(self: Expression) error{InvalidCast}![]const u8 {
        return switch (self) {
            .string => |s| s,
            .void, .int, .@"var", .fn_call => error.InvalidCast,
        };
    }

    pub fn asVar(self: Expression) error{InvalidCast}![]const u8 {
        return switch (self) {
            .@"var" => |v| v,
            .void, .int, .string, .fn_call => error.InvalidCast,
        };
    }

    pub fn asFnCall(self: Expression) error{InvalidCast}!FnCall {
        return switch (self) {
            .fn_call => |f| f,
            .void, .int, .string, .@"var" => error.InvalidCast,
        };
    }

    pub fn eql(a: Expression, b: Expression) bool {
        switch (a) {
            .string => |a_str| switch (b) {
                .string => |b_str| {
                    return std.mem.eql(u8, a_str, b_str);
                },
                else => return false,
            },
            .@"var" => |a_var| switch (b) {
                .@"var" => |b_var| {
                    return std.mem.eql(u8, a_var, b_var);
                },
                else => return false,
            },
            .void, .int, .fn_call => {
                return std.meta.eql(a, b);
            },
        }
    }
};

/// NOTE: Interpreter contains two arenas: `arena` and `scratch`. In some
/// usecases of this scripting language, they both have the same
/// scope/lifetime, but in other cases they have different applications. I will
/// give two examples:
///
/// * If this scripting language is evaluated in a repl-fashion, it makes sense
/// for arena to never be cleared unless manually told so to keep defined
/// variables and functions, while scratch is purely meant for internal
/// expression evaluations. Therefore they have different lifetimes/purposes.
///
/// * If this scripting language is evaluated as a chatbot script, and a new
/// context is created for each expression/command, then arena and scratch are
/// both reset after each expression, thus sharing the same lifetime.
pub fn Interpreter(comptime Context: type) type {
    return struct {
        const Self = @This();

        /// See the doc-comment for `Interpreter` to see the difference between
        /// the `arena` and `scratch` allocators.
        ///
        /// Generally this is more for permanent/very long living memory
        /// allocations.
        arena: Allocator,
        /// See the doc-comment for `Interpreter` to see the difference between
        /// the `arena` and `scratch` allocators.
        ///
        /// Generally this gets reset after evaluating every top-level
        /// expression.
        scratch: Allocator,

        /// Macro-style replacement. When using a variable in a script, the program
        /// simply replaces that variable with the corresponding expression.
        vars: std.StringHashMap(Expression),
        /// Similar to `vars`, except that it replaces the function call with the
        /// expression result of the function.
        fns: std.StringHashMap(FnCall.Impl(Context)),

        /// May be used in builtins.
        ctx: *Context,

        pub fn init(arena: Allocator, scratch: Allocator, ctx: *Context) Self {
            const vars = std.StringHashMap(Expression).init(arena);
            const fns = std.StringHashMap(FnCall.Impl(Context)).init(arena);

            return .{
                .arena = arena,
                .scratch = scratch,
                .vars = vars,
                .fns = fns,
                .ctx = ctx,
            };
        }

        pub fn deinit(self: *Self) void {
            self.vars.deinit();
            self.fns.deinit();
        }

        pub fn addBuiltins(self: *Self) Allocator.Error!void {
            for (Builtins(Context).all) |b| {
                try self.fns.put(b.name, b.impl);
            }
        }

        pub fn eval(self: *Self, expr: Expression) Error!Expression {
            switch (expr) {
                .void, .int, .string => return expr,
                .@"var" => |v| {
                    const replacement = self.vars.get(v) orelse return error.UnknownVariable;
                    return try self.eval(replacement);
                },
                .fn_call => |f| {
                    const impl = self.fns.get(f.name) orelse return error.UnknownFn;
                    return try impl.@"fn"(impl.payload, self, f.args);
                },
            }
        }
    };
}

/// No builtin uses Context. Those should be defined outside, and appended at
/// the caller's leisure.
pub fn Builtins(comptime Context: type) type {
    return struct {
        const Impl = FnCall.Impl(Context);

        const Builtin = struct {
            name: []const u8,
            impl: Impl,
        };

        const all = [_]Builtin{
            .{ .name = "log", .impl = log },
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

        const log = Impl{
            .@"fn" = struct {
                pub fn call(_: ?*anyopaque, itp: *Interpreter(Context), args: []const Expression) Error!Expression {
                    var buf = std.ArrayList(u8).empty;
                    defer buf.deinit(itp.scratch);

                    for (args) |arg| {
                        const val = try itp.eval(arg);
                        switch (val) {
                            .int => |d| {
                                const s = try std.fmt.allocPrint(itp.scratch, "{d}", .{d});
                                try buf.appendSlice(itp.scratch, s);
                            },
                            .string => |s| {
                                try buf.appendSlice(itp.scratch, s);
                            },
                            .void, .@"var", .fn_call => {
                                return error.InvalidCast;
                            },
                        }
                    }
                    std.debug.print("{s}\n", .{buf.items});
                    return .void;
                }
            }.call,
        };

        const @"if" = Impl{
            .@"fn" = struct {
                pub fn call(_: ?*anyopaque, itp: *Interpreter(Context), args: []const Expression) Error!Expression {
                    if (args.len != 3) return error.InvalidArgumentsCount;

                    const val = try itp.eval(args[0]);
                    const cond = try val.asString();

                    if (std.mem.eql(u8, cond, "true")) {
                        return try itp.eval(args[1]);
                    } else if (std.mem.eql(u8, cond, "false")) {
                        return try itp.eval(args[2]);
                    } else {
                        return error.InvalidArgumentValue;
                    }
                }
            }.call,
        };

        const eql = Impl{
            .@"fn" = struct {
                pub fn call(_: ?*anyopaque, itp: *Interpreter(Context), args: []const Expression) Error!Expression {
                    if (args.len != 2) return error.InvalidArgumentsCount;

                    const a = try itp.eval(args[0]);
                    const b = try itp.eval(args[1]);

                    return .{ .string = if (a.eql(b)) "true" else "false" };
                }
            }.call,
        };

        const let = Impl{
            .@"fn" = struct {
                pub fn call(_: ?*anyopaque, itp: *Interpreter(Context), args: []const Expression) Error!Expression {
                    if (args.len != 2) return error.InvalidArgumentsCount;

                    const name = try args[0].asVar();
                    const as = try itp.eval(args[1]);
                    try itp.vars.put(name, as);
                    return .void;
                }
            }.call,
        };

        const define = Impl{
            .@"fn" = struct {
                pub fn call(_: ?*anyopaque, itp: *Interpreter(Context), args: []const Expression) Error!Expression {
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

                    const payload = try itp.arena.create(Payload);
                    payload.* = .{
                        .name = name,
                        .inner_args = @constCast(inner_args),
                        .to_eval = args[2],
                    };

                    const impl = Impl{
                        .payload = payload,
                        .@"fn" = struct {
                            pub fn call(untyped_payload: ?*anyopaque, called_itp: *Interpreter(Context), called_args: []const Expression) Error!Expression {
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
                                    const gop = try called_itp.vars.getOrPut(@"var");
                                    if (gop.found_existing) return error.Shadowing;

                                    gop.value_ptr.* = called_args[i];
                                }

                                const ret = try called_itp.eval(p.to_eval);

                                for (p.inner_args) |inner_arg| {
                                    const @"var" = try inner_arg.asVar();
                                    if (!called_itp.vars.remove(@"var")) {
                                        // This should never happen.
                                        unreachable;
                                    }
                                }

                                return ret;
                            }
                        }.call,
                    };

                    try itp.fns.put(name, impl);

                    return .void;
                }
            }.call,
        };

        const @"and" = Impl{
            .@"fn" = struct {
                pub fn call(_: ?*anyopaque, itp: *Interpreter(Context), args: []const Expression) Error!Expression {
                    if (args.len == 0) return error.InvalidArgumentsCount;

                    for (args) |arg| {
                        const val = try itp.eval(arg);
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

        const not = Impl{
            .@"fn" = struct {
                pub fn call(_: ?*anyopaque, itp: *Interpreter(Context), args: []const Expression) Error!Expression {
                    if (args.len != 1) return error.InvalidArgumentsCount;

                    const val = try itp.eval(args[0]);
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
            pub fn f1(comptime Inner: type) type {
                return struct {
                    pub fn f2(ctx: *Interpreter(Inner), args: []const Expression) Error!struct { u64, u64 } {
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
                };
            }
        }.f1(Context).f2;

        const gt = Impl{
            .@"fn" = struct {
                pub fn call(_: ?*anyopaque, itp: *Interpreter(Context), args: []const Expression) Error!Expression {
                    const v = try twoTuple(itp, args);
                    return Expression{ .string = if (v.@"0" > v.@"1") "true" else "false" };
                }
            }.call,
        };

        const gte = Impl{
            .@"fn" = struct {
                pub fn call(_: ?*anyopaque, itp: *Interpreter(Context), args: []const Expression) Error!Expression {
                    const v = try twoTuple(itp, args);
                    return Expression{ .string = if (v.@"0" >= v.@"1") "true" else "false" };
                }
            }.call,
        };

        const ls = Impl{
            .@"fn" = struct {
                pub fn call(_: ?*anyopaque, itp: *Interpreter(Context), args: []const Expression) Error!Expression {
                    const v = try twoTuple(itp, args);
                    return Expression{ .string = if (v.@"0" < v.@"1") "true" else "false" };
                }
            }.call,
        };

        const lse = Impl{
            .@"fn" = struct {
                pub fn call(_: ?*anyopaque, itp: *Interpreter(Context), args: []const Expression) Error!Expression {
                    const v = try twoTuple(itp, args);
                    return Expression{ .string = if (v.@"0" <= v.@"1") "true" else "false" };
                }
            }.call,
        };

        const repeat = Impl{
            .@"fn" = struct {
                pub fn call(_: ?*anyopaque, itp: *Interpreter(Context), args: []const Expression) Error!Expression {
                    if (args.len != 2) return error.InvalidArgumentsCount;

                    // This will be cleaned up as ctx.scratch gets cleanup when having
                    // evaluated this master expression.
                    var buf = std.ArrayList(u8).empty;

                    const n = n: {
                        const val = try itp.eval(args[1]);
                        break :n try val.asInt();
                    };
                    for (0..n) |_| {
                        const res = try itp.eval(args[0]);
                        const tmp = res.asString();
                        if (tmp != error.InvalidCast) {
                            const slice = try tmp;
                            try buf.appendSlice(itp.scratch, slice);
                        }
                    }
                    if (buf.items.len != 0) {
                        return .{ .string = buf.items };
                    }

                    return .void;
                }
            }.call,
        };

        const add = Impl{
            .@"fn" = struct {
                pub fn call(_: ?*anyopaque, itp: *Interpreter(Context), args: []const Expression) Error!Expression {
                    if (args.len == 0) return error.InvalidArgumentsCount;

                    var ret: u64 = 0;
                    for (args) |arg| {
                        const val = try itp.eval(arg);
                        const int = try val.asInt();
                        ret += int;
                    }

                    return .{ .int = ret };
                }
            }.call,
        };

        const do = Impl{
            .@"fn" = struct {
                pub fn call(_: ?*anyopaque, itp: *Interpreter(Context), args: []const Expression) Error!Expression {
                    for (args) |arg| {
                        _ = try itp.eval(arg);
                    }

                    return .void;
                }
            }.call,
        };
    };
}
