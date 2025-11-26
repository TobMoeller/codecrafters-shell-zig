const std = @import("std");

pub const TokenKind = enum {
    eof,
    word,
};

pub const Token = struct {
    kind: TokenKind,
    lexeme: []const u8,
};

const State = enum {
    normal,
    inSingleQuotes,
};

pub const Lexer = struct {
    state: State = State.normal,
    input: []const u8,
    index: usize = 0,
    lexemeBuffer: std.ArrayList(u8),

    pub fn init(input: []const u8) Lexer {
        return .{
            .input = input,
            .lexemeBuffer = .empty
        };
    }

    pub fn next(self: *Lexer, allocator: std.mem.Allocator) !Token {
        self.lexemeBuffer.clearRetainingCapacity();

        while (self.index < self.input.len) : (self.index += 1) {
            const c = self.input[self.index];

            switch (self.state) {
                .normal => switch (c) {
                    '\'' => {
                        self.state = .inSingleQuotes;
                    },
                    ' ', '\t', '\n' => {
                        if (self.lexemeBuffer.items.len > 0) {
                            return try self.createWordToken(allocator);
                        } else {
                            continue;
                        }
                    },
                    else => {
                        try self.lexemeBuffer.append(allocator, c);
                    }
                },
                .inSingleQuotes => switch (c) {
                    '\'' => {
                        self.state = .normal;
                    },
                    else => {
                        try self.lexemeBuffer.append(allocator, c);
                    }
                }
            }
        }

        if (self.lexemeBuffer.items.len > 0) {
            return try self.createWordToken(allocator);
        } else {
            return .{ .kind = .eof, .lexeme = "" };
        }
    }

    fn createWordToken(self: *Lexer, allocator: std.mem.Allocator) !Token {
        return .{
            .kind = .word,
            .lexeme = try self.lexemeBuffer.toOwnedSlice(allocator)
        };
    }
};
