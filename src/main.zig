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

    while (true) {
        const received = try signal.receive(alloc, &.{ .{ .prefixed_text_message = "!" }, .reaction });
        defer received.parsed.deinit();

        const msg = received.parsed.value;
        const source = msg.envelope.source;
        const name = msg.sourceName() orelse continue;

        switch (received.type) {
            .prefixed_text_message => |_| {
                const text = msg.textMessage() orelse continue;

                const chat_msg = try std.fmt.allocPrint(alloc, "{s} [{s}]> {s}", .{name, source, text});
                defer alloc.free(chat_msg);
                std.debug.print("{s}\n", .{chat_msg});

                if (std.mem.eql(u8, text[1..], "echo")) {
                    try signal.sendMessage(alloc, "hello, world!", .{ .phone = source });
                }

                if (std.mem.eql(u8, text[1..], "Hej är jag snygg?")) {
                    try signal.sendMessage(alloc, "Hell no motherfucker...", .{ .phone = source });
                }
            },
            .reaction => {
                const reaction = msg.reaction().?;
                if (reaction.isRemove) continue;

                const target = reaction.targetAuthor;
                const chat_msg = try std.fmt.allocPrint(alloc, "{s} [{s}] reacted with {s} to {s}", .{name, source, reaction.emoji, target});
                defer alloc.free(chat_msg);
                std.debug.print("{s}\n", .{chat_msg});
            },
            else => {},
        }
    }
}
