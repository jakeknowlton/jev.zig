const std = @import("std");
const question = @import("question.zig");

pub const Noul = struct {
    /// Probability that the answer is yes.
    probability: f64,
};

pub fn Choice(comptime E: type) type {
    return struct {
        /// The option the server picked.
        choice: E,
        probabilities: std.EnumArray(E, f64),
        /// Concentration of the distribution between 0 and 1.
        confidence: f64,
    };
}

pub fn Score(comptime E: type) type {
    return struct {
        /// Probability-weighted level index between 0 and `len - 1`.
        score: f64,
        probabilities: std.EnumArray(E, f64),
        confidence: f64,

        /// The single most probable level.
        pub fn likeliest(self: @This()) E {
            return std.enums.values(E)[std.sort.argMax(f64, &self.probabilities.values, {}, std.sort.asc(f64)).?];
        }
    };
}

pub const Usage = struct {
    input_tokens: u64 = 0,
    output_tokens: u64 = 0,
};

/// The answers struct with one field per question.
pub fn Answers(comptime Q: type) type {
    const info = @typeInfo(Q);
    if (info != .@"struct" or info.@"struct".is_tuple)
        @compileError("jev: questions must be a struct literal like .{ .id = jev.noul(\"...\") }");
    const fields = info.@"struct".fields;
    if (fields.len == 0) @compileError("jev: ask at least one question");
    var types: [fields.len]type = undefined;
    for (fields, &types) |f, *t| {
        if (!question.isQuestion(f.type))
            @compileError("jev: question '" ++ f.name ++ "' must be built with jev.noul, jev.choice or jev.score");
        t.* = f.type.Answer;
    }
    return @Struct(.auto, null, std.meta.fieldNames(Q), &types, &@splat(.{}));
}

/// Owns no memory.
pub fn Result(comptime Q: type) type {
    return struct {
        answers: Answers(Q),
        usage: Usage = .{},
        model_buf: [64]u8 = undefined,
        model_len: u8 = 0,

        /// The versioned model that answered, e.g. `jev-1.13.0`.
        pub fn model(self: *const @This()) []const u8 {
            return self.model_buf[0..self.model_len];
        }
    };
}
