const std = @import("std");
const Bot = @import("Bot.zig");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer {
        const deinit_status = gpa.deinit();
        if (deinit_status == .leak) {
            std.log.err("memory leak", .{});
        }
    }
    const alloc = gpa.allocator();

    var args = std.process.args();
    if (!args.skip()) return;

    const config_path = args.next() orelse return error.NoConfigPath;

    var bot = try Bot.init(alloc, config_path);
    defer bot.deinit();

    try bot.run(alloc);
}
