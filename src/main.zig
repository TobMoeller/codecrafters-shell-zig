const std = @import("std");

var stdout_writer = std.fs.File.stdout().writerStreaming(&.{});
const stdout = &stdout_writer.interface;

var stderr_writer = std.fs.File.stderr().writerStreaming(&.{});
const stderr = &stderr_writer.interface;

var stdin_buffer: [10*1024]u8 = undefined;
var stdin_reader = std.fs.File.stdin().readerStreaming(&stdin_buffer);
const stdin = &stdin_reader.interface;

const Builtin = enum {
    exit
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
            }

            command.args[i-1] = input_part;
            command.argLength = i;
        }

        return command;
    }
};

pub fn main() !void {
    // TODO: Uncomment the code below to pass the first stage
    while (true) {
        try stdout.print("$ ", .{});
        const input = try stdin.takeDelimiter('\n') orelse "";

        var command: Command = try Command.createFromInput(input);
        try handleCommand(&command);
    }
}

pub fn handleCommand(command: *Command) !void {
    command.builtin = std.meta.stringToEnum(Builtin, command.exec);
    if (command.builtin != null) {
        try runBuiltinCommand(command);
    }

    try stderr.print("{s}: command not found\n", .{command.exec});
}

pub fn runBuiltinCommand(command: *Command) !void {
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
        }
    }
}
