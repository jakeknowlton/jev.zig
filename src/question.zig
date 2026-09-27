//! Question constructors. Each returns a struct type carrying `kind`, `Answer`
//! and a `jsonStringify` that writes the wire form.
const std = @import("std");
const answer = @import("answer.zig");
const Stringify = std.json.Stringify;

const Kind = enum { noul, choice, score };

/// Pre-encoded JSON written verbatim and unvalidated. Must be one JSON value.
pub const RawJson = struct {
    bytes: []const u8,

    pub fn jsonStringify(self: RawJson, w: *Stringify) Stringify.Error!void {
        try w.beginWriteRaw();
        try w.writer.writeAll(self.bytes);
        w.endWriteRaw();
    }
};

/// A yes/no question answered with the probability of yes.
pub fn noul(instructions: anytype) Noul(@TypeOf(instructions), @TypeOf(null), @TypeOf(null)) {
    return .{ .instructions = instructions, .yes = null, .no = null };
}

/// Picks one tag of `E`. `descriptions` is a struct literal keyed by tags of
/// `E`. Tags left out are sent as `null`.
pub fn choice(comptime E: type, instructions: anytype, descriptions: anytype) Choice(E, @TypeOf(instructions), @TypeOf(descriptions)) {
    return .{ .instructions = instructions, .descriptions = descriptions };
}

/// Rates on the ordered scale of `E` from its first tag to its last. Only the
/// descriptions reach the model, so every tag needs one.
pub fn score(comptime E: type, instructions: anytype, descriptions: anytype) Score(E, @TypeOf(instructions), @TypeOf(descriptions)) {
    return .{ .instructions = instructions, .descriptions = descriptions };
}

fn Noul(comptime I: type, comptime Y: type, comptime N: type) type {
    checkContent(I, "noul instructions");
    return struct {
        instructions: I,
        yes: Y,
        no: N,

        pub const kind: Kind = .noul;
        pub const Answer = answer.Noul;

        /// Describes what yes (near 1) and no (near 0) mean.
        pub fn criteria(self: @This(), yes: anytype, no: anytype) Noul(I, @TypeOf(yes), @TypeOf(no)) {
            checkContent(@TypeOf(yes), "noul criteria");
            checkContent(@TypeOf(no), "noul criteria");
            return .{ .instructions = self.instructions, .yes = yes, .no = no };
        }

        pub fn jsonStringify(self: @This(), w: *Stringify) Stringify.Error!void {
            try w.beginObject();
            try w.objectField("type");
            try w.write("noul");
            try w.objectField("instructions");
            try w.write(self.instructions);
            if (Y != @TypeOf(null)) {
                try w.objectField("criteria");
                try w.write(.{ .true = self.yes, .false = self.no });
            }
            try w.endObject();
        }
    };
}

fn Choice(comptime E: type, comptime I: type, comptime D: type) type {
    checkEnum(E, 1, 255, "choice");
    checkContent(I, "choice instructions");
    checkDescriptions(E, D, false);
    return struct {
        instructions: I,
        descriptions: D,

        pub const kind: Kind = .choice;
        pub const Answer = answer.Choice(E);

        pub fn jsonStringify(self: @This(), w: *Stringify) Stringify.Error!void {
            try w.beginObject();
            try w.objectField("type");
            try w.write("choice");
            try w.objectField("instructions");
            try w.write(self.instructions);
            try w.objectField("criteria");
            try w.beginObject();
            inline for (@typeInfo(E).@"enum".fields) |f| {
                try w.objectField(f.name);
                try w.write(if (@hasField(D, f.name)) @field(self.descriptions, f.name) else null);
            }
            try w.endObject();
            try w.endObject();
        }
    };
}

fn Score(comptime E: type, comptime I: type, comptime D: type) type {
    checkEnum(E, 2, 10, "score");
    checkContent(I, "score instructions");
    checkDescriptions(E, D, true);
    return struct {
        instructions: I,
        descriptions: D,

        pub const kind: Kind = .score;
        pub const Answer = answer.Score(E);

        pub fn jsonStringify(self: @This(), w: *Stringify) Stringify.Error!void {
            try w.beginObject();
            try w.objectField("type");
            try w.write("score");
            try w.objectField("instructions");
            try w.write(self.instructions);
            try w.objectField("criteria");
            try w.beginArray();
            inline for (@typeInfo(E).@"enum".fields) |f| try w.write(@field(self.descriptions, f.name));
            try w.endArray();
            try w.endObject();
        }
    };
}

pub fn isQuestion(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "kind") and @TypeOf(T.kind) == Kind;
}

fn checkEnum(comptime E: type, comptime min: usize, comptime max: usize, comptime what: []const u8) void {
    const info = @typeInfo(E);
    if (info != .@"enum" or !info.@"enum".is_exhaustive)
        @compileError("jev: " ++ @typeName(E) ++ " must be an exhaustive enum for " ++ what);
    const n = info.@"enum".fields.len;
    if (n < min or n > max)
        @compileError(std.fmt.comptimePrint("jev: {s} has {d} tags but {s} needs {d} to {d}", .{ @typeName(E), n, what, min, max }));
}

pub fn checkContent(comptime T: type, comptime what: []const u8) void {
    switch (@typeInfo(T)) {
        .bool, .int, .float, .comptime_int, .comptime_float, .void, .null => @compileError("jev: " ++ what ++ " is a " ++ @typeName(T) ++ " but must be a string, struct, tuple or slice"),
        else => {},
    }
}

fn checkDescriptions(comptime E: type, comptime D: type, comptime complete: bool) void {
    const info = @typeInfo(D);
    if (info != .@"struct" or (info.@"struct".is_tuple and info.@"struct".fields.len > 0))
        @compileError("jev: descriptions for " ++ @typeName(E) ++ " must be a struct literal keyed by its tags");
    for (info.@"struct".fields) |f| {
        if (!@hasField(E, f.name)) @compileError("jev: " ++ @typeName(E) ++ " has no tag '" ++ f.name ++ "'");
        checkContent(f.type, "description of '" ++ f.name ++ "'");
    }
    if (complete) for (@typeInfo(E).@"enum".fields) |f| {
        if (!@hasField(D, f.name)) @compileError("jev: " ++ @typeName(E) ++ " score level '" ++ f.name ++ "' needs a description");
    };
}
