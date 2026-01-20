const std = @import("std");
const Allocator = std.mem.Allocator;
const Signal = @import("Signal.zig");

pub const Error = error{
    SignalError,
    OutOfMemory,
    /// Expression could not cast to the wanted type.
    InvalidCast,
    /// Tried to get an unknown variable from Context.vars.
    UnknownVariable,
    /// Tried to get an unknown function implementation from Context.fns.
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
    pub const Impl = struct {
        /// Used to catch some data in a closure-like fashion. Sometimes, ex:
        /// define in builtin_fns.zig, it is necessary to wrap some data to get
        /// certain vars or fns.
        payload: ?*anyopaque = null,
        @"fn": *const fn (payload: ?*anyopaque, ctx: *Context, args: []const Expression) Error!Expression,
    };

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

pub const Context = struct {
    /// Be careful with this arena. `Context` is a very long-living structure,
    /// so only allocate on the arena if absolutely necessary, ex permanent
    /// memory storage.
    arena: Allocator,
    /// Use this inside functions to not leak memory in the long run. Gets
    /// reset after evaluating every master expression (i.e expressions at the
    /// root level).
    scratch: Allocator,

    /// Macro-style replacement. When using a variable in a script, the program
    /// simply replaces that variable with the corresponding expression.
    vars: std.StringHashMap(Expression),
    /// Similar to `vars`, except that it replaces the function call with the
    /// expression result of the function.
    fns: std.StringHashMap(FnCall.Impl),

    /// May be used in builtins.
    signal: *Signal,

    pub fn init(arena: Allocator, scratch: Allocator, signal: *Signal) Context {
        const vars = std.StringHashMap(Expression).init(arena);
        const fns = std.StringHashMap(FnCall.Impl).init(arena);

        return .{
            .arena = arena,
            .scratch = scratch,
            .vars = vars,
            .fns = fns,
            .signal = signal,
        };
    }

    pub fn deinit(self: *Context) void {
        self.vars.deinit();
        self.fns.deinit();
    }

    pub fn eval(self: *Context, expr: Expression) Error!Expression {
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
