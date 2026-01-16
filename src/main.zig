const std = @import("std");
const Allocator = std.mem.Allocator;
const Child = std.process.Child;

const signal = @import("signal.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}).init;
    defer {
        const deinit_status = gpa.deinit();
        if (deinit_status == .leak) {
            std.log.err("memory leak", .{});
        }
    }
    const alloc = gpa.allocator();

    var args = std.process.args();
    _ = args.next() orelse return error.Unexpected;

    const action = args.next() orelse return error.Unexpected;
    if (std.mem.eql(u8, action, "send-message")) {
        const message = args.next() orelse return error.Unexpected;
        const user = args.next() orelse return error.Unexpected;
        std.debug.assert(args.next() == null);

        std.debug.print("message = {s}\n", .{message});
        std.debug.print("user = {s}\n", .{user});

        const status = try signal.sendMessage(alloc, message, .{ .user = user });
        std.debug.print("=== Signal status: {s}\n", .{status});
    } else if (std.mem.eql(u8, action, "receive")) {
        std.debug.assert(args.next() == null);
        while (true) {
            const json = try signal.receive(alloc);
            defer alloc.free(json);

            const parsed = try signal.Message.parse(alloc, json);
            defer parsed.deinit();

            if (parsed.value.textMessage()) |text| {
                std.debug.print("{s}>\t{s}\n", .{parsed.value.envelope.sourceName.?, text});
            }
        }
    }
}
