const std = @import("std");
const app = @import("app");
const lang = app.lang;
const Expression = lang.Expression;

test "expression eql" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    const alloc = gpa.allocator();

    var e1 = Expression{ .string = "hello world" };
    var e2 = Expression{ .string = "bonjour tout le monde" };
    try std.testing.expect(!e1.eql(e2));

    // NOTE: Wow pesky zig...
    // The string references static memory, which might not always be the case
    // in our strings.
    const slice = try std.fmt.allocPrint(alloc, "bonjour {s}", .{"tout le monde"});
    e1 = Expression{ .string = slice };
    e2 = Expression{ .string = "bonjour tout le monde" };
    try std.testing.expect(e1.eql(e2));

    e1 = .void;
    e2 = Expression{ .string = "bonjour tout le monde" };
    try std.testing.expect(!e1.eql(e2));

    e1 = .void;
    e2 = .void;
    try std.testing.expect(e1.eql(e2));

    e1 = Expression{ .int = 45 };
    e2 = Expression{ .int = 45 };
    try std.testing.expect(e1.eql(e2));

    e1 = Expression{ .int = 35 };
    try std.testing.expect(!e1.eql(e2));

    e1 = Expression{ .variable = "var" };
    e2 = Expression{ .variable = "variable" };
    try std.testing.expect(!e1.eql(e2));

    e1 = Expression{ .variable = "var" };
    e2 = Expression{ .variable = "var" };
    try std.testing.expect(e1.eql(e2));

    e1 = Expression{ .fn_call = .{
        .name = "echo",
        .args = &.{ .{ .string = "name" }, .{ .int = 45 } },
    } };
    e2 = Expression{ .fn_call = .{
        .name = "echo",
        .args = &.{ .{ .string = "name" }, .{ .int = 45 } },
    } };
    try std.testing.expect(e1.eql(e2));

    e1 = Expression{ .fn_call = .{
        .name = "echo",
        .args = &.{ .{ .string = "name" }, .{ .int = 45 } },
    } };
    e2 = Expression{ .fn_call = .{
        .name = "world",
        .args = &.{ .{ .string = "name" }, .{ .int = 45 } },
    } };
    try std.testing.expect(!e1.eql(e2));

    e1 = Expression{ .fn_call = .{
        .name = "world",
        .args = &.{ .{ .string = "name" }, .{ .int = 45 } },
    } };
    e2 = Expression{ .fn_call = .{
        .name = "world",
        .args = &.{ .{ .variable = "name" }, .{ .int = 45 } },
    } };
    try std.testing.expect(!e1.eql(e2));

    e1 = Expression{ .int = 1 };
    try std.testing.expect(!e1.eql(e2));
}
