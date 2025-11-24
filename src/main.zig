const std = @import("std");

var stdout_writer = std.fs.File.stdout().writerStreaming(&.{});
const stdout = &stdout_writer.interface;

var stderr_writer = std.fs.File.stderr().writerStreaming(&.{});
const stderr = &stderr_writer.interface;

var stdin_buffer: [10*1024]u8 = undefined; // TODO dynamically allocate?
var stdin_reader = std.fs.File.stdin().readerStreaming(&stdin_buffer);
const stdin = &stdin_reader.interface;

const Builtin = enum {
    exit,
    echo,
    type,
    pwd,
    cd,
    pub fn fromString(string: []const u8) ?Builtin {
        return std.meta.stringToEnum(Builtin, string);
    }
};

const CommandType = enum {
    builtin,
    path,
};

const Executable = union(CommandType) {
    builtin: Builtin,
    path: []const u8,
};

const CommandError = error {
    ExecutableNotFound,
};

const Command = struct {
    args: std.ArrayList([]const u8),
    executable: Executable,

    pub fn parseInput(allocator: std.mem.Allocator) !Command {
        var command: Command = .{
            .args = .empty,
            .executable = undefined,
        };

        const input = try stdin.takeDelimiter('\n') orelse "";

        var splitIterator = std.mem.splitScalar(u8, input, ' ');
        while (splitIterator.next()) |arg| {
            if (arg.len > 0) {
                try command.cloneAndAppendArg(allocator, arg);
            }
        }

        if (command.args.items.len < 1) return error.NoExecutableProvided;
        command.executable = determineExecutable(allocator, command.args.items[0])
            catch |err| switch (err) {
                CommandError.ExecutableNotFound => {
                    try stderr.print("{s}: command not found\n", .{command.args.items[0]});
                    return err;
                },
                else => return err,
            };

        return command;
    }

    pub fn cloneAndAppendArg(self: *Command, allocator: std.mem.Allocator, arg: []const u8) !void {
        const argCopy = try allocator.dupe(u8, arg);
        try self.args.append(allocator, argCopy);
    }

    pub fn deinit(self: *Command, allocator: std.mem.Allocator) !void {
        self.args.deinit(allocator);
    }

    pub fn determineExecutable(allocator: std.mem.Allocator, command: []const u8) !Executable {
        if (command.len < 1) return error.NoExecutableProvided;

        const maybeBuiltin = Builtin.fromString(command);
        if (maybeBuiltin != null) {
            return .{ .builtin = maybeBuiltin.? };
        } else {
            const path = try findExecutableInPath(allocator, command);
            return .{ .path = path };
        }
    }

    pub fn findExecutableInPath(allocator: std.mem.Allocator, command: []const u8) ![]const u8 {
        var env = try std.process.getEnvMap(allocator);
        defer env.deinit();

        const pathVariable = env.get("PATH") orelse return error.UnableToRetrievePath;
        var pathIterator = std.mem.splitScalar(u8, pathVariable, ':');

        while (pathIterator.next()) |dirPath| {
            const filePath = try std.fs.path.join(allocator, &.{dirPath, command});
            var file = std.fs.openFileAbsolute(filePath, .{.mode = .read_only}) catch continue;
            defer file.close();

            const fileMode = file.mode() catch continue;
            if (fileMode & std.posix.S.IXUSR != 0) { // TODO handle IXGRP / IXOTH and windows?
                return filePath;
            }
        } 

        return CommandError.ExecutableNotFound;
    }

    pub fn run(self: *Command, allocator: std.mem.Allocator) !void {
        switch (self.executable) {
            .builtin => try runBuiltinCommand(allocator, self),
            .path => {
                var child: std.process.Child = .init(self.args.items, allocator);
                _ = try child.spawnAndWait();
            }
        }
    }

    pub fn runBuiltinCommand(allocator: std.mem.Allocator, command: *Command) !void {
        switch (command.executable.builtin) {
            .exit => {
                var exitValue: u8 = 0;

                if (command.args.items.len > 1 and command.args.items[1].len > 0) {
                    const providedExitValue: u8 = std.fmt.parseInt(u8, command.args.items[1], 10) 
                        catch return std.process.exit(exitValue);

                    if (providedExitValue <= 255) {
                        exitValue = providedExitValue;
                    }
                }

                std.process.exit(exitValue);
            },
            .echo => {
                var i: u8 = 1;
                while (i < command.args.items.len) : (i += 1) {
                    if (i+1 == command.args.items.len) {
                        try stdout.print("{s}", .{command.args.items[i]});
                    } else {
                        try stdout.print("{s} ", .{command.args.items[i]});
                    }
                }
                try stdout.print("\n", .{});
            },
            .type => {
                if (command.args.items.len > 0 and command.args.items[1].len > 0) {
                    const commandArg = command.args.items[1];
                    const executable: ?Executable = determineExecutable(allocator, commandArg) catch null;
                    if (executable == null) {
                        try stderr.print("{s}: not found\n", .{commandArg});
                        return;
                    }
                    switch (executable.?) {
                        .builtin => try stdout.print("{s} is a shell builtin\n", .{commandArg}),
                        .path => try stdout.print("{s} is {s}\n", .{commandArg, executable.?.path})
                    }
                } else {
                    try stderr.print("No Command provided\n", .{});
                }
            },
            .pwd => {
                const cwd = try std.fs.cwd().realpathAlloc(allocator, ".");
                try stdout.print("{s}\n", .{cwd});
            },
            .cd => {
                if (command.args.items.len > 1 and command.args.items[1].len > 0) {
                    var dir = std.fs.cwd().openDir(command.args.items[1], .{})
                        catch {
                            try stderr.print("cd: {s}: No such file or directory\n", .{command.args.items[1]});
                            return;
                        };
                    defer dir.close();
                    try dir.setAsCwd();
                } else {
                    try stderr.print("No destination provided\n", .{});
                }
            },
        }
    }
};

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    while (true) {
        var arenaAllocator: std.heap.ArenaAllocator = .init(allocator);
        defer arenaAllocator.deinit();
        const arena = arenaAllocator.allocator();
        try stdout.print("$ ", .{});

        var command: Command = Command.parseInput(arena) catch continue;
        try command.run(arena);
    }
}
