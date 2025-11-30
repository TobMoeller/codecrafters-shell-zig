const std = @import("std");
const cmd = @import("command.zig");

var stdout_writer = std.fs.File.stdout().writerStreaming(&.{});
pub const stdout = &stdout_writer.interface;

var stderr_writer = std.fs.File.stderr().writerStreaming(&.{});
pub const stderr = &stderr_writer.interface;

var stdin_buffer: [10*1024]u8 = undefined; // TODO dynamically allocate?
var stdin_reader = std.fs.File.stdin().readerStreaming(&stdin_buffer);
pub const stdin = &stdin_reader.interface;

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    while (true) {
        var arenaAllocator: std.heap.ArenaAllocator = .init(allocator);
        defer arenaAllocator.deinit();
        const arena = arenaAllocator.allocator();

        try stdout.print("$ ", .{});
        const input = try stdin.takeDelimiter('\n') orelse "";

        var command: cmd.Command = cmd.Command.parseInput(arena, input) catch continue;
        try command.run(arena);
    }
}
