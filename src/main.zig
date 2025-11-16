const std = @import("std");

var stdout_writer = std.fs.File.stdout().writerStreaming(&.{});
const stdout = &stdout_writer.interface;

var stderr_writer = std.fs.File.stderr().writerStreaming(&.{});
const stderr = &stderr_writer.interface;

var stdin_buffer: [10*1024]u8 = undefined;
var stdin_reader = std.fs.File.stdin().readerStreaming(&stdin_buffer);
const stdin = &stdin_reader.interface;

const Builtin = enum {
    exit,
    echo,
    type,
};

const Command = struct {
    exec: []const u8,
    args: [50][]const u8,
    argLength: u8 = 0,
    builtin: ?Builtin = null,

    pub fn createFromInput(input: []const u8) !Command {
        var i: u8 = 0;
        var command: Command = .{
            .exec = undefined,
            .args = undefined
        };

        var splitIterator = std.mem.splitScalar(u8, input, ' ');
        while (splitIterator.next()) |input_part| : (i += 1) {
            if (i == 0) {
                command.exec = input_part;
                continue;
            } else if (i == 50) {
                break; // TODO: implement error handling for too many arguments
            }

            command.args[i-1] = input_part;
            command.argLength = i;
        }

        return command;
    }
};

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    while (true) {
        try stdout.print("$ ", .{});
        const input = try stdin.takeDelimiter('\n') orelse "";

        var command: Command = try Command.createFromInput(input);
        try handleCommand(allocator, &command);
    }
}

pub fn handleCommand(allocator: std.mem.Allocator, command: *Command) !void {
    command.builtin = std.meta.stringToEnum(Builtin, command.exec);
    if (command.builtin != null) {
        return try runBuiltinCommand(allocator, command);
    }

    try stderr.print("{s}: command not found\n", .{command.exec});
}

pub fn runBuiltinCommand(allocator: std.mem.Allocator, command: *Command) !void {
    switch (command.builtin.?) {
        .exit => {
            var exitValue: u8 = 0;

            if (command.argLength > 0 and command.args[0].len > 0) {
                const providedExitValue: u8 = std.fmt.parseInt(u8, command.args[0], 10) 
                    catch std.process.exit(exitValue);

                if (providedExitValue <= 255) {
                    exitValue = providedExitValue;
                }
            }

            std.process.exit(exitValue);
        },
        .echo => {
            var i: u8 = 0;
            while (i < command.argLength) : (i += 1) {
                if (i+1 == command.argLength) {
                    try stdout.print("{s}", .{command.args[i]});
                } else {
                    try stdout.print("{s} ", .{command.args[i]});
                }
            }
            try stdout.print("\n", .{});
        },
        .type => {
            if (command.argLength > 0 and command.args[0].len > 0) {
                if (std.meta.stringToEnum(Builtin, command.args[0]) != null) {
                    try stdout.print("{s} is a shell builtin\n", .{command.args[0]});
                } else {
                    try typeFindCommandInPath(allocator, command);
                }
            }
        }
    }
}

// TODO refactor naming and structure (add command path to command struct, create find command method)
pub fn typeFindCommandInPath(allocator: std.mem.Allocator, command: *Command) !void {
    var env = try std.process.getEnvMap(allocator);
    defer env.deinit();

    const pathVariable = env.get("PATH") orelse return try typeNotFound(command);
    var pathIterator = std.mem.splitScalar(u8, pathVariable, ':');

    while (pathIterator.next()) |path| {
        if (try typeFindCommandInDir(allocator, command, path)) return;
    } 

    try typeNotFound(command);
}

pub fn typeFindCommandInDir(allocator: std.mem.Allocator, command: *Command, path: []const u8) !bool {
    var dir = std.fs.openDirAbsolute(path, .{.access_sub_paths = false, .iterate = true}) catch return false;
    defer dir.close();

    var dirWalker = try dir.walk(allocator);

    while (true) {
        const maybe_entry = dirWalker.next() catch continue;
        const entry = maybe_entry orelse break;

        if (entry.kind == .file and std.mem.eql(u8, command.args[0], entry.basename)) { // TODO handle symlinks

            var file = dir.openFile(entry.basename, .{.mode = .read_only}) catch continue;
            const fileStat = file.stat() catch continue;

            if (fileStat.mode & std.posix.S.IXUSR != 0) { // TODO handle IXGRP / IXOTH and windows?
                const absolutePath = try std.fs.path.join(allocator, &.{path, command.args[0]});
                try stderr.print("{s} is {s}\n", .{command.args[0], absolutePath});

                return true;
            }

            // try stdout.print("{s} - {b} & {b} = {b}\n", .{entry.basename, fileStat.mode, std.posix.S.IXUSR, fileStat.mode & std.posix.S.IXUSR});
        }
    }

    return false;
}

pub fn typeNotFound(command: *Command) !void {
    try stderr.print("{s}: not found\n", .{command.args[0]});
}

pub fn exit(exitValue: u8) void {
    std.process.exit(exitValue);
}
