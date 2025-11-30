const std = @import("std");
const cmd = @import("command.zig");
const c = @cImport({
    @cInclude("stdio.h");
    @cInclude("stdlib.h");
    @cInclude("string.h");
    @cInclude("readline/readline.h");
});

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
    c.rl_attempted_completion_function = completion;

    while (true) {
        var arenaAllocator: std.heap.ArenaAllocator = .init(allocator);
        defer arenaAllocator.deinit();
        const arena = arenaAllocator.allocator();

        try buildCompletionCandidates(arena);
        defer completionCandidates.clearAndFree(arena);

        const line = c.readline("$ ");
        defer std.c.free(line);

        if (line == null) {
            std.debug.print("EOF\n", .{});
            continue;
        }

        const input = std.mem.span(line);

        var command: cmd.Command = cmd.Command.parseInput(arena, input) catch continue;
        try command.run(arena);
    }
}

var completionCandidates: std.ArrayList([]const u8) = .empty;

fn completion(text: [*c]const u8, start: c_int, stop: c_int) callconv(.c) [*c][*c]u8 {
    _ = stop;
    var matches: [*c][*c]u8 = null;

    if (start == 0) {
        matches = c.rl_completion_matches(text, commandGenerator);
    }

    return matches;
}

fn commandGenerator(text: [*c]const u8, state: c_int) callconv(.c) [*c]u8 {
    const localState = struct {
        var optionIndex: usize = 0;
    };
    const command = std.mem.span(text);

    // reset local state
    if (state == 0) {
        localState.optionIndex = 0;
    }

    while (localState.optionIndex < completionCandidates.items.len) {
        const index = localState.optionIndex;
        localState.optionIndex += 1;

        if (std.mem.startsWith(u8, completionCandidates.items[index], command)) {
            const dup =  std.heap.c_allocator.dupeZ(u8, completionCandidates.items[index]) catch null;
            return dup.?.ptr;
        }
    }

    return null;
}

fn buildCompletionCandidates(allocator: std.mem.Allocator) !void {
    inline for (@typeInfo(cmd.Builtin).@"enum".fields) |builtin| {
        try completionCandidates.append(allocator, builtin.name);
    }

    const pathVariable = std.process.getEnvVarOwned(allocator, "PATH") catch return error.UnableToRetrievePath;
    defer allocator.free(pathVariable);
    var pathIterator = std.mem.splitScalar(u8, pathVariable, ':');

    while (pathIterator.next()) |dirPath| {
        var dir = std.fs.openDirAbsolute(dirPath, .{.iterate = true}) catch continue;
        defer dir.close();

        var iterator = dir.iterate();

        while (true) {
            const maybeEntry = iterator.next() catch break;
            const entry = maybeEntry orelse break;
            if (entry.kind != .file) continue;

            const fileStat = dir.statFile(entry.name) catch continue;
            if (fileStat.mode & std.posix.S.IXUSR != 0) { // TODO handle IXGRP / IXOTH and windows?
                try completionCandidates.append(allocator, try allocator.dupe(u8, entry.name));
            }
        }
    } 
}

