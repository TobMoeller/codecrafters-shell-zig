const std = @import("std");

var stdout_writer = std.fs.File.stdout().writerStreaming(&.{});
const stdout = &stdout_writer.interface;

var stderr_writer = std.fs.File.stderr().writerStreaming(&.{});
const stderr = &stderr_writer.interface;

var stdin_buffer: [10*1024]u8 = undefined;
var stdin_reader = std.fs.File.stdin().readerStreaming(&stdin_buffer);
const stdin = &stdin_reader.interface;

pub fn main() !void {
    // TODO: Uncomment the code below to pass the first stage
    while (true) {
        try stdout.print("$ ", .{});
        const command = try stdin.takeDelimiter('\n');
        try stderr.print("{s}: command not found\n", .{command orelse ""});
    }
}
