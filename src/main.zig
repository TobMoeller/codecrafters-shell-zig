const std = @import("std");
const lex = @import("lexer.zig");

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
    tokens: std.ArrayList(lex.Token),
    executable: Executable,

    pub fn parseInput(allocator: std.mem.Allocator) !Command {
        var command: Command = .{
            .args = .empty,
            .tokens = .empty,
            .executable = undefined,
        };

        const input = try stdin.takeDelimiter('\n') orelse "";

        // var splitIterator = std.mem.splitScalar(u8, input, ' ');
        // while (splitIterator.next()) |arg| {
        //     if (arg.len > 0) {
        //         try command.cloneAndAppendArg(allocator, arg);
        //     }
        // }

        var lexer: lex.Lexer = .init(input);

        while (true) {
            const token = try lexer.next(allocator);
            if (token.kind == .eof) {
                break;
            }
            try command.tokens.append(allocator, token);
            try command.args.append(allocator, token.lexeme);
        }

        if (command.tokens.items.len < 1) return error.NoExecutableProvided;
        command.executable = determineExecutable(allocator, command.tokens.items[0].lexeme)
            catch |err| switch (err) {
                CommandError.ExecutableNotFound => {
                    try stderr.print("{s}: command not found\n", .{command.tokens.items[0].lexeme});
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
        self.tokens.deinit(allocator);
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
        const pathVariable = std.process.getEnvVarOwned(allocator, "PATH") catch return error.UnableToRetrievePath;
        defer allocator.free(pathVariable);
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
                // TODO generate args from tokens
                var child: std.process.Child = .init(self.args.items, allocator);
                _ = try child.spawnAndWait();
            }
        }
    }

    pub fn runBuiltinCommand(allocator: std.mem.Allocator, command: *Command) !void {
        switch (command.executable.builtin) {
            .exit => {
                var exitValue: u8 = 0;

                if (command.tokens.items.len > 1 and command.tokens.items[1].lexeme.len > 0) {
                    const providedExitValue: u8 = std.fmt.parseInt(u8, command.tokens.items[1].lexeme, 10) 
                        catch return std.process.exit(exitValue);

                    if (providedExitValue <= 255) {
                        exitValue = providedExitValue;
                    }
                }

                std.process.exit(exitValue);
            },
            .echo => {
                var i: u8 = 1;
                while (i < command.tokens.items.len) : (i += 1) {
                    if (i+1 == command.tokens.items.len) {
                        try stdout.print("{s}", .{command.tokens.items[i].lexeme});
                    } else {
                        try stdout.print("{s} ", .{command.tokens.items[i].lexeme});
                    }
                }
                try stdout.print("\n", .{});
            },
            .type => {
                if (command.tokens.items.len > 0 and command.tokens.items[1].lexeme.len > 0) {
                    const commandArg = command.tokens.items[1].lexeme;
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
                var destination: []const u8 = undefined;

                if (command.tokens.items.len <= 1 or std.mem.eql(u8, command.tokens.items[1].lexeme, "~")) {
                    destination = std.process.getEnvVarOwned(allocator, "HOME") catch {
                        try stderr.print("No HOME defined", .{});
                        return;
                    };

                } else if (command.tokens.items.len > 1 and command.tokens.items[1].lexeme.len > 0) {
                    destination = command.tokens.items[1].lexeme;

                } else {

                    try stderr.print("No destination provided\n", .{});
                    return;
                }

                var dir = std.fs.cwd().openDir(destination, .{})
                    catch {
                        try stderr.print("cd: {s}: No such file or directory\n", .{command.tokens.items[1].lexeme});
                        return;
                    };
                defer dir.close();
                try dir.setAsCwd();
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
