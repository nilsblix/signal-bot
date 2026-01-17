const std = @import("std");
const signal = @import("signal.zig");
const Allocator = std.mem.Allocator;

// This expression-based language is meant to fulfill a couple of things.
//
// I want to create a chatbot which interacts with a groupchat to perform
// certain commands, such as roll an n-sided dice, or select o group member to
// do something etc.
//
// To achieve this I want to have all of the bot's available commands stored in
// some database, and can therefore edit the available commands without having
// to recompile the program/even start and quit it.
//
// My thought is therefore to create a small expression-based language, with
// macro-like variable and function calling.
//
// ```script
// let(some_number, 6)
//
// define(ping, args(author), echo("@", author))
//
// repeat(ping("nilsblix"), some_number)
// ```
//
// The above script defines a sortof macro called `ping` which when called
// simply replaces ping(...) with its implementation. It then calls `ping` with
// the argument `"nilsblix"` 5 times.
//
// All the function builtins (let, define, repeat etc...) are defined outside of the script, as to make the
// language completely usage-agnostic.

pub const Error = error{
    /// An unknown error was encountered. Commonly `Allocator.Error.OutOfMemory`.
    Abort,
    /// Expression could not cast to the wanted type.
    InvalidCast,
    /// Tried to get an unknown variable from Context.vars.
    UnknownVariable,
    /// Tried to get an unknown function implementation from Context.fns.
    UnknownFn,
    /// An incorrect number of arguments were supplied to a function call.
    InvalidArgumentsCount,
};

pub const FnCall = struct {
    pub const Impl = *const fn (ctx: *Context, args: []const Expression) Error!Expression;

    args: []const Expression,
    /// Gets matched to an implementation (of type Impl) during
    /// runtime/evaluation. This makes it possible to define new functions
    /// during evaluation of the script.
    name: []const u8,
};

pub const Expression = union(enum) {
    @"void",
    int: u64,
    string: []const u8,
    @"var": []const u8,
    fn_call: FnCall,

    pub fn asInt(self: Expression) error{InvalidCast}!u64 {
        return switch (self) {
            .int => |d| d,
            .@"void", .string, .@"var", .fn_call => error.InvalidCast,
        };
    }

    pub fn asString(self: Expression) error{InvalidCast}![]const u8 {
        return switch (self) {
            .string => |s| s,
            .@"void", .int, .@"var", .fn_call => error.InvalidCast,
        };
    }
};

pub const Context = struct {
    arena: std.heap.ArenaAllocator,
    target: signal.Target,

    /// Macro-style replacement. When using a variable in a script, the program
    /// simply replaces that variable with the corresponding expression.
    vars: std.StringHashMap(Expression),
    /// Similar to `vars`, except that it replaces the function call with the
    /// expression result of the function.
    fns: std.StringHashMap(FnCall.Impl),

    pub fn init(arena: std.heap.ArenaAllocator, target: signal.Target) Context {
        const vars = std.StringHashMap(Expression).init(arena.child_allocator);
        const fns = std.StringHashMap(FnCall.Impl).init(arena.child_allocator);

        return .{
            .arena = arena,
            .target = target,
            .vars = vars,
            .fns = fns,
        };
    }

    pub fn deinit(self: *Context) void {
        self.vars.deinit();
        self.fns.deinit();
    }

    pub fn eval(self: *Context, expr: Expression) Error!Expression {
        switch (expr) {
            .@"void", .int, .string => return expr,
            .@"var" => |v| {
                const replacement = self.vars.get(v) orelse return error.UnknownVariable;
                return try self.eval(replacement);
            },
            .fn_call => |f| {
                const impl = self.fns.get(f.name) orelse return error.UnknownFn;
                return try impl(self, f.args);
            },
        }
    }
};
