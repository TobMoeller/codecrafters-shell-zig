const std = @import("std");
const lex = @import("lexer.zig");
const root = @import("root");

pub const Builtin = enum {
    exit,
    echo,
    type,
    pwd,
    cd,
    pub fn fromString(string: []const u8) ?Builtin {
        return std.meta.stringToEnum(Builtin, string);
    }
    pub const names = namesBlock: {
        const enumInfo = @typeInfo(Builtin).@"enum";
        var arr: [enumInfo.fields.len][]const u8 = undefined;

        for (enumInfo.fields, 0..) |field, i| {
            arr[i] = field.name;
        }

        break :namesBlock arr;
    };
};

pub const CommandType = enum {
    builtin,
    path,
};

pub const Executable = union(CommandType) {
    builtin: Builtin,
    path: []const u8,
};

pub const CommandError = error {
    ExecutableNotFound,
};

pub const Command = struct {
    args: std.ArrayList([]const u8),
    tokens: std.ArrayList(lex.Token),
    executable: Executable,

    pub fn parseInput(allocator: std.mem.Allocator, input: []const u8) !Command {
        var command: Command = .{
            .args = .empty,
            .tokens = .empty,
            .executable = undefined,
        };

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
                    try root.stderr.print("{s}: command not found\n", .{command.tokens.items[0].lexeme});
                    return err;
                },
                else => return err,
            };

        return command;
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
                        try root.stdout.print("{s}", .{command.tokens.items[i].lexeme});
                    } else {
                        try root.stdout.print("{s} ", .{command.tokens.items[i].lexeme});
                    }
                }
                try root.stdout.print("\n", .{});
            },
            .type => {
                if (command.tokens.items.len > 0 and command.tokens.items[1].lexeme.len > 0) {
                    const commandArg = command.tokens.items[1].lexeme;
                    const executable: ?Executable = determineExecutable(allocator, commandArg) catch null;
                    if (executable == null) {
                        try root.stderr.print("{s}: not found\n", .{commandArg});
                        return;
                    }
                    switch (executable.?) {
                        .builtin => try root.stdout.print("{s} is a shell builtin\n", .{commandArg}),
                        .path => try root.stdout.print("{s} is {s}\n", .{commandArg, executable.?.path})
                    }
                } else {
                    try root.stderr.print("No Command provided\n", .{});
                }
            },
            .pwd => {
                const cwd = try std.fs.cwd().realpathAlloc(allocator, ".");
                try root.stdout.print("{s}\n", .{cwd});
            },
            .cd => {
                var destination: []const u8 = undefined;

                if (command.tokens.items.len <= 1 or std.mem.eql(u8, command.tokens.items[1].lexeme, "~")) {
                    destination = std.process.getEnvVarOwned(allocator, "HOME") catch {
                        try root.stderr.print("No HOME defined", .{});
                        return;
                    };

                } else if (command.tokens.items.len > 1 and command.tokens.items[1].lexeme.len > 0) {
                    destination = command.tokens.items[1].lexeme;

                } else {

                    try root.stderr.print("No destination provided\n", .{});
                    return;
                }

                var dir = std.fs.cwd().openDir(destination, .{})
                    catch {
                        try root.stderr.print("cd: {s}: No such file or directory\n", .{command.tokens.items[1].lexeme});
                        return;
                    };
                defer dir.close();
                try dir.setAsCwd();
            },
        }
    }
};
