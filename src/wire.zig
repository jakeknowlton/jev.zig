//! JSON encoding of requests and decoding of responses.
const std = @import("std");
const answer = @import("answer.zig");
const Io = std.Io;
const Value = std.json.Value;

pub const EncodeError = error{ InvalidRequest, WriteFailed };
pub const DecodeError = error{ InvalidResponse, OutOfMemory };

/// Tolerance for server rounding in probabilities.
const tolerance = 0.05;

pub fn encode(w: *Io.Writer, state: anytype, questions: anytype, model: []const u8) EncodeError!void {
    try validate(state);
    try validate(questions);
    try validate(model);
    var s: std.json.Stringify = .{ .writer = w };
    try s.beginObject();
    try s.objectField("state");
    try s.write(state);
    try s.objectField("model");
    try s.write(model);
    try s.objectField("questions");
    try s.write(questions);
    try s.endObject();
}

/// `std.json` writes invalid UTF-8 as a number array and non-finite floats as
/// bare words. This rejects both before encoding.
fn validate(v: anytype) error{InvalidRequest}!void {
    if (@TypeOf(v) == Value) return switch (v) {
        .string, .number_string => |s| validate(s),
        .float => |f| validate(f),
        .array => |a| for (a.items) |x| try validate(x),
        .object => |o| for (o.keys(), o.values()) |k, x| {
            try validate(k);
            try validate(x);
        },
        else => {},
    };
    switch (@typeInfo(@TypeOf(v))) {
        .@"struct" => |s| inline for (s.fields) |f| try validate(@field(v, f.name)),
        .optional => if (v) |p| try validate(p),
        .@"union" => |u| if (u.tag_type != null) switch (v) {
            inline else => |x| try validate(x),
        },
        .pointer => |p| switch (p.size) {
            .one => try validate(v.*),
            .slice => if (p.child == u8) {
                if (!std.unicode.utf8ValidateSlice(v)) return error.InvalidRequest;
            } else for (v) |x| try validate(x),
            .many => if (p.sentinel() != null) try validate(std.mem.span(v)),
            .c => {},
        },
        .array => |a| if (a.child == u8) {
            if (!std.unicode.utf8ValidateSlice(&v)) return error.InvalidRequest;
        } else for (v) |x| try validate(x),
        .float => if (!std.math.isFinite(v)) return error.InvalidRequest,
        else => {},
    }
}

pub fn decode(comptime Q: type, gpa: std.mem.Allocator, body: []const u8) DecodeError!answer.Result(Q) {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const root = std.json.parseFromSliceLeaky(Value, arena.allocator(), body, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidResponse,
    };
    const answers = member(root, "answers") orelse return error.InvalidResponse;

    var result: answer.Result(Q) = .{ .answers = undefined, .usage = undefined };
    inline for (@typeInfo(Q).@"struct".fields) |f| {
        const a = member(answers, f.name) orelse return error.InvalidResponse;
        if (member(a, "type")) |t| {
            if (t != .string or !std.mem.eql(u8, t.string, @tagName(f.type.kind))) return error.InvalidResponse;
        }
        @field(result.answers, f.name) = switch (f.type.kind) {
            .noul => .{ .probability = try probability(member(a, "noul")) },
            .choice => try decodeChoice(f.type.Answer, a),
            .score => try decodeScore(f.type.Answer, a),
        };
    }
    if (member(root, "model")) |m| if (m == .string) {
        if (m.string.len > result.model_buf.len) return error.InvalidResponse;
        @memcpy(result.model_buf[0..m.string.len], m.string);
        result.model_len = @intCast(m.string.len);
    };
    const usage = member(root, "usage") orelse return error.InvalidResponse;
    result.usage = .{
        .input_tokens = try count(member(usage, "input_tokens")),
        .output_tokens = try count(member(usage, "output_tokens")),
    };
    return result;
}

fn decodeChoice(comptime A: type, a: Value) DecodeError!A {
    const E = @FieldType(A, "probabilities").Key;
    var probabilities: std.EnumArray(E, f64) = .initFill(0);
    var sum: f64 = 0;
    const map = try entries(a);
    for (map.keys(), map.values()) |key, v| if (std.meta.stringToEnum(E, key)) |tag| {
        const p = try probability(v);
        probabilities.set(tag, p);
        sum += p;
    };
    if (@abs(sum - 1) > tolerance) return error.InvalidResponse;
    const chosen = member(a, "choice") orelse return error.InvalidResponse;
    if (chosen != .string) return error.InvalidResponse;
    return .{
        .choice = std.meta.stringToEnum(E, chosen.string) orelse return error.InvalidResponse,
        .probabilities = probabilities,
        .confidence = try probability(member(a, "confidence")),
    };
}

fn decodeScore(comptime A: type, a: Value) DecodeError!A {
    const levels = std.enums.values(@FieldType(A, "probabilities").Key);
    var probabilities: @FieldType(A, "probabilities") = .initFill(0);
    var sum: f64 = 0;
    const map = try entries(a);
    for (map.keys(), map.values()) |key, v| if (std.fmt.parseInt(usize, key, 10)) |i| {
        if (i >= levels.len) continue;
        const p = try probability(v);
        probabilities.set(levels[i], p);
        sum += p;
    } else |_| {};
    if (@abs(sum - 1) > tolerance) return error.InvalidResponse;
    const s = try number(member(a, "score"));
    if (s < 0 or s > @as(f64, @floatFromInt(levels.len - 1))) return error.InvalidResponse;
    return .{ .score = s, .probabilities = probabilities, .confidence = try probability(member(a, "confidence")) };
}

/// The `probabilities` object of an answer.
fn entries(a: Value) error{InvalidResponse}!std.json.ObjectMap {
    const object = member(a, "probabilities") orelse return error.InvalidResponse;
    return if (object == .object) object.object else error.InvalidResponse;
}

fn member(v: Value, key: []const u8) ?Value {
    return if (v == .object) v.object.get(key) else null;
}

fn number(v: ?Value) error{InvalidResponse}!f64 {
    const n: f64 = switch (v orelse return error.InvalidResponse) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        else => return error.InvalidResponse,
    };
    return if (std.math.isFinite(n)) n else error.InvalidResponse;
}

fn probability(v: ?Value) error{InvalidResponse}!f64 {
    const p = try number(v);
    if (p < -tolerance or p > 1 + tolerance) return error.InvalidResponse;
    return @min(@max(p, 0), 1);
}

fn count(v: ?Value) error{InvalidResponse}!u64 {
    return switch (v orelse return error.InvalidResponse) {
        .integer => |i| if (i < 0) error.InvalidResponse else @as(u64, @intCast(i)),
        else => error.InvalidResponse,
    };
}

const testing = std.testing;
const question = @import("question.zig");

const Team = enum { billing, technical, sales };
const Severity = enum { minor, degraded, outage };

const fixture_questions = .{
    .urgent = question.noul("Needs attention today?").criteria("Blocks normal use", "Can wait"),
    .team = question.choice(Team, "Which team?", .{ .billing = "Charges and refunds", .technical = question.RawJson{ .bytes = "{\"what\":\"Bugs\"}" } }),
    .severity = question.score(Severity, "How severe?", .{ .minor = "Cosmetic", .degraded = "Workaround exists", .outage = "Unusable" }),
};

test encode {
    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try encode(&out.writer, .{ .ticket = "Charged twice" }, fixture_questions, "jev-latest");
    try testing.expectEqualStrings(
        \\{"state":{"ticket":"Charged twice"},"model":"jev-latest","questions":{"urgent":{"type":"noul","instructions":"Needs attention today?","criteria":{"true":"Blocks normal use","false":"Can wait"}},"team":{"type":"choice","instructions":"Which team?","criteria":{"billing":"Charges and refunds","technical":{"what":"Bugs"},"sales":null}},"severity":{"type":"score","instructions":"How severe?","criteria":["Cosmetic","Workaround exists","Unusable"]}}}
    , out.written());

    try testing.expectError(error.InvalidRequest, encode(&out.writer, "\xff", fixture_questions, "jev-latest"));
    try testing.expectError(error.InvalidRequest, encode(&out.writer, .{ .x = std.math.nan(f64) }, fixture_questions, "jev-latest"));
    try testing.expectError(error.InvalidRequest, encode(&out.writer, std.json.Value{ .string = "\xff" }, fixture_questions, "jev-latest"));
    try testing.expectError(error.InvalidRequest, encode(&out.writer, "x", fixture_questions, "\xff"));
}

pub const response_fixture =
    \\{"model":"jev-1.13.0","answers":{
    \\  "urgent":{"type":"noul","noul":0.87},
    \\  "team":{"type":"choice","choice":"billing","probabilities":{"billing":0.85,"technical":0.1,"sales":0.05,"legacy":0},"confidence":0.79},
    \\  "severity":{"type":"score","score":1.43,"probabilities":{"0":0,"1":0.57,"2":0.43},"legend":{"0":"Cosmetic"},"confidence":0.61}
    \\},"usage":{"input_tokens":296,"output_tokens":20},"quota":{"used":1}}
;

test decode {
    const Q = @TypeOf(fixture_questions);
    const r = try decode(Q, testing.allocator, response_fixture);
    try testing.expectEqual(0.87, r.answers.urgent.probability);
    try testing.expectEqual(.billing, r.answers.team.choice);
    try testing.expectEqual(0.1, r.answers.team.probabilities.get(.technical));
    try testing.expectEqual(0.79, r.answers.team.confidence);
    try testing.expectEqual(1.43, r.answers.severity.score);
    try testing.expectEqual(0.57, r.answers.severity.probabilities.get(.degraded));
    try testing.expectEqual(.degraded, r.answers.severity.likeliest());
    try testing.expectEqualStrings("jev-1.13.0", r.model());
    try testing.expectEqual(296, r.usage.input_tokens);

    const minimal = try decode(Q, testing.allocator,
        \\{"answers":{"urgent":{"noul":1},"team":{"choice":"sales","probabilities":{"sales":1.01},"confidence":1},"severity":{"score":2,"probabilities":{"2":1},"confidence":1}},"usage":{"input_tokens":1,"output_tokens":1}}
    );
    try testing.expectEqual(1, minimal.answers.team.probabilities.get(.sales));
    try testing.expectEqualStrings("", minimal.model());

    for ([_][]const u8{
        "{",
        \\{"answers":{}}
        ,
        \\{"answers":{"urgent":{"type":"choice","noul":0.5},"team":{"choice":"sales","probabilities":{"sales":1},"confidence":1},"severity":{"score":2,"probabilities":{"2":1},"confidence":1}}}
        ,
        \\{"answers":{"urgent":{"noul":0.5},"team":{"choice":"nope","probabilities":{"sales":1},"confidence":1},"severity":{"score":2,"probabilities":{"2":1},"confidence":1}}}
        ,
        \\{"answers":{"urgent":{"noul":0.5},"team":{"choice":"sales","probabilities":{"sales":0.5,"legacy":0.5},"confidence":1},"severity":{"score":2,"probabilities":{"2":1},"confidence":1}}}
        ,
        \\{"answers":{"urgent":{"noul":1.2},"team":{"choice":"sales","probabilities":{"sales":1},"confidence":1},"severity":{"score":2,"probabilities":{"2":1},"confidence":1}}}
        ,
        \\{"answers":{"urgent":{"noul":0.5},"team":{"choice":"sales","probabilities":{"sales":1},"confidence":1},"severity":{"score":7,"probabilities":{"2":1},"confidence":1}}}
        ,
        \\{"answers":{"urgent":{"noul":0.5},"team":{"choice":"sales","probabilities":{"sales":1},"confidence":1},"severity":{"score":2,"probabilities":{"2":0.5,"9":0.5},"confidence":1}}}
        ,
        \\{"answers":{"urgent":{"noul":1},"team":{"choice":"sales","probabilities":{"sales":1},"confidence":1},"severity":{"score":2,"probabilities":{"2":1},"confidence":1}},"usage":{"input_tokens":296,"output_tokens":"20"}}
    }, 0..) |body, i| testing.expectError(error.InvalidResponse, decode(Q, testing.allocator, body)) catch |err| {
        std.debug.print("case {d}\n", .{i});
        return err;
    };
}

// Fuzz with `zig build test --fuzz -Doptimize=ReleaseSafe`. The Debug fuzz
// runner does not compile on Zig 0.16.0.
test "decode survives arbitrary bytes" {
    try testing.fuzz({}, fuzzDecode, .{ .corpus = &.{response_fixture} });
}

fn fuzzDecode(_: void, smith: *testing.Smith) !void {
    var buf: [4096]u8 = undefined;
    const body = buf[0..smith.slice(&buf)];
    const r = decode(@TypeOf(fixture_questions), testing.allocator, body) catch |err| switch (err) {
        error.InvalidResponse => return,
        error.OutOfMemory => return err,
    };
    try expectUnit(r.answers.urgent.probability);
    try expectDistribution(&r.answers.team.probabilities.values, r.answers.team.confidence);
    try expectDistribution(&r.answers.severity.probabilities.values, r.answers.severity.confidence);
    try testing.expect(r.answers.severity.score >= 0 and r.answers.severity.score <= 2);
}

fn expectUnit(p: f64) !void {
    try testing.expect(p >= 0 and p <= 1);
}

fn expectDistribution(probabilities: []const f64, confidence: f64) !void {
    var sum: f64 = 0;
    for (probabilities) |p| {
        try expectUnit(p);
        sum += p;
    }
    try testing.expect(@abs(sum - 1) <= tolerance);
    try expectUnit(confidence);
}
