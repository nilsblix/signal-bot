const std = @import("std");
const Allocator = std.mem.Allocator;
const json = std.json;
const Signal = @import("Signal.zig");

pub const Trust = u8;

pub const Minimum = struct {
    to_interact: Trust,
    to_write_cmd: Trust,
    admin: Trust,
};

// The chat to send the results to.
target: Signal.Chat,
cmd_prefix: []const u8,

event_uri: []const u8,
rpc_uri: []const u8,

/// The trust level property is useful for enabling only certain users the
/// ability to run potentially "dangerous" commands, such as evaluating raw
/// nils-script expressions.
minimum: Minimum,

const Config = @This();

pub fn parse(alloc: Allocator, body: []const u8) !json.Parsed(Config) {
    const opt = json.ParseOptions{
        .allocate = .alloc_always,
        .parse_numbers = true,
        .ignore_unknown_fields = true,
    };
    return try json.parseFromSlice(Config, alloc, body, opt);
}
