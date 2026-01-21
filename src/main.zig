const std = @import("std");
const Config = @import("Config.zig");
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

    var f = try std.fs.cwd().openFile(config_path, .{});
    defer f.close();

    var reader_buf: [4096]u8 = undefined;
    var reader = f.reader(&reader_buf);
    const n = try reader.getSize();

    const config_json = try reader.interface.readAlloc(alloc, n);
    const parsed = try Config.parse(alloc, config_json);

    var bot = try Bot.init(alloc, parsed.value);
    defer bot.deinit();

    try bot.run(alloc);
}
