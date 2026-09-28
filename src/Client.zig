//! Client for `POST /v1/systemone`. It is immutable after `init` and safe to
//! share across threads. A call blocks until the server answers or the `Io`
//! cancels it.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const answer = @import("answer.zig");
const question = @import("question.zig");
const wire = @import("wire.zig");
const Retry = @import("Retry.zig");
const Diagnostics = @import("Diagnostics.zig");
const Client = @This();

pub const Transport = @import("transport.zig").Transport;

gpa: Allocator,
io: Io,
/// Heap-allocated because `std.http` connections point back at it.
http: *std.http.Client,
url: []u8,
/// Points into `url`.
uri: std.Uri,
authorization: []u8,
model: []u8,
retry: Retry,
timeout: ?Io.Duration,
/// Replaces `http` when set before the first call. For tests.
transport: ?Transport = null,

pub const Options = struct {
    /// The client copies it and zeroes the copy at `deinit`.
    api_key: []const u8,
    base_url: []const u8 = "https://api.typesafe.ai",
    model: []const u8 = "jev-latest",
    retry: Retry = .{},
    /// Bounds each attempt. Each attempt then runs on its own task, so `gpa`
    /// must be thread-safe.
    timeout: ?Io.Duration = null,
};

pub const AskOptions = struct {
    diagnostics: ?*Diagnostics = null,
    model: ?[]const u8 = null,
};

pub const InitError = error{ OutOfMemory, InvalidBaseUrl, InvalidApiKey };

pub const Error = error{
    /// 400 or 422, or a request that failed local validation.
    InvalidRequest,
    /// 401.
    Unauthorized,
    /// 403.
    Forbidden,
    /// 429 after retries.
    RateLimited,
    /// 529 after retries.
    Overloaded,
    /// Other 5xx after retries.
    ServerError,
    UnexpectedStatus,
    /// See `Diagnostics.cause`.
    ConnectionFailed,
    /// An attempt exceeded `Options.timeout`.
    Timeout,
    Canceled,
    /// A 2xx body that the decoder rejected or that exceeds the size cap.
    InvalidResponse,
    OutOfMemory,
};

pub fn init(gpa: Allocator, io: Io, options: Options) InitError!Client {
    if (std.mem.indexOfAny(u8, options.api_key, "\r\n") != null) return error.InvalidApiKey;
    const url = try std.mem.concat(gpa, u8, &.{ std.mem.trimEnd(u8, options.base_url, "/"), "/v1/systemone" });
    errdefer gpa.free(url);
    const uri = std.Uri.parse(url) catch return error.InvalidBaseUrl;
    if (std.http.Client.Protocol.fromUri(uri) == null) return error.InvalidBaseUrl;
    const authorization = try std.mem.concat(gpa, u8, &.{ "Bearer ", options.api_key });
    errdefer gpa.free(authorization);
    const model = try gpa.dupe(u8, options.model);
    errdefer gpa.free(model);
    const http = try gpa.create(std.http.Client);
    http.* = .{ .allocator = gpa, .io = io };
    return .{ .gpa = gpa, .io = io, .http = http, .url = url, .uri = uri, .authorization = authorization, .model = model, .retry = options.retry, .timeout = options.timeout };
}

/// Every call must have returned.
pub fn deinit(self: *Client) void {
    self.http.deinit();
    self.gpa.destroy(self.http);
    std.crypto.secureZero(u8, self.authorization);
    self.gpa.free(self.authorization);
    self.gpa.free(self.url);
    self.gpa.free(self.model);
    self.* = undefined;
}

/// `state` is a string or any value `std.json` can write. `questions` is a
/// struct literal of `jev.noul`, `jev.choice` and `jev.score`.
pub fn ask(self: *Client, state: anytype, questions: anytype, options: AskOptions) Error!answer.Result(@TypeOf(questions)) {
    question.checkContent(@TypeOf(state), "state");
    var body: Io.Writer.Allocating = .init(self.gpa);
    defer body.deinit();
    wire.encode(&body.writer, state, questions, options.model orelse self.model) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        error.InvalidRequest => |e| return e,
    };
    const response = try self.send(body.written(), options.diagnostics);
    defer self.gpa.free(response);
    return wire.decode(@TypeOf(questions), self.gpa, response);
}

fn send(self: *Client, body: []u8, diagnostics: ?*Diagnostics) Error![]u8 {
    const t = self.transport orelse Transport.http(self.http);
    const request: Transport.Request = .{ .uri = self.uri, .authorization = self.authorization, .body = body };
    var attempts: u16 = 1;
    while (true) : (attempts += 1) {
        var out: Io.Writer.Allocating = .init(self.gpa);
        defer out.deinit();
        var cause: ?anyerror = null;
        const outcome = self.attempt(t, request, &out.writer, &cause);
        if (diagnostics) |d| {
            d.* = .{ .attempts = attempts, .cause = cause };
            if (outcome) |r| {
                d.status = r.status;
                d.retry_after_ms = r.retry_after_ms;
            } else |_| {}
            d.setBody(out.written());
        }
        const err: Error = if (outcome) |r| statusError(r.status) orelse return out.toOwnedSlice() else |e| e;
        if (attempts > self.retry.max_retries or !retryable(err)) return err;
        const retry_after_ms = if (outcome) |r| r.retry_after_ms else |_| null;
        const ms = self.retry.delayMs(attempts - 1, retry_after_ms, jitter(self.io));
        if (ms > 0) try self.io.sleep(.fromMilliseconds(@intCast(ms)), .awake);
    }
}

/// Races the send against `timeout`. Falls back to a plain send when the `Io`
/// cannot run a task concurrently.
fn attempt(self: *Client, t: Transport, request: Transport.Request, out: *Io.Writer, cause: *?anyerror) (Transport.Error || error{Timeout})!Transport.Response {
    const timeout = self.timeout orelse return t.send(request, out, cause);
    const Race = union(enum) { sent: Transport.Error!Transport.Response, timer: Io.Cancelable!void };
    var buffer: [2]Race = undefined;
    var select: Io.Select(Race) = .init(self.io, &buffer);
    select.concurrent(.sent, Transport.send, .{ t, request, out, cause }) catch return t.send(request, out, cause);
    defer select.cancelDiscard();
    const deadline: Io.Timeout = .{ .duration = .{ .raw = timeout, .clock = .awake } };
    select.concurrent(.timer, Io.Timeout.sleep, .{ deadline, self.io }) catch {};
    const first = try select.await();
    select.cancelDiscard();
    return switch (first) {
        .sent => |sent| sent,
        .timer => |slept| {
            try slept;
            cause.* = error.Timeout;
            return error.Timeout;
        },
    };
}

fn statusError(status: std.http.Status) ?Error {
    return switch (@intFromEnum(status)) {
        200...299 => null,
        400, 422 => error.InvalidRequest,
        401 => error.Unauthorized,
        403 => error.Forbidden,
        429 => error.RateLimited,
        529 => error.Overloaded,
        500...528, 530...599 => error.ServerError,
        else => error.UnexpectedStatus,
    };
}

fn retryable(err: Error) bool {
    return switch (err) {
        error.ConnectionFailed, error.Timeout, error.RateLimited, error.Overloaded, error.ServerError => true,
        else => false,
    };
}

/// Uniform in [0, 1) from the top 53 bits of a random u64.
fn jitter(io: Io) f64 {
    var buf: [8]u8 = undefined;
    io.random(&buf);
    return @as(f64, @floatFromInt(std.mem.readInt(u64, &buf, .little) >> 11)) / (1 << 53);
}

const testing = std.testing;

const Mock = struct {
    replies: []const Reply,
    calls: usize = 0,

    const Reply = struct { status: u10, body: []const u8 = "", retry_after_ms: ?u64 = null, delay_ms: i64 = 0 };

    fn reply(ctx: *anyopaque, request: Transport.Request, out: *Io.Writer, cause: *?anyerror) Transport.Error!Transport.Response {
        const self: *Mock = @ptrCast(@alignCast(ctx));
        std.debug.assert(std.mem.eql(u8, "example.test", request.uri.host.?.percent_encoded));
        std.debug.assert(std.mem.eql(u8, "Bearer k", request.authorization));
        const next = self.replies[@min(self.calls, self.replies.len - 1)];
        self.calls += 1;
        if (next.delay_ms > 0) testing.io.sleep(.fromMilliseconds(next.delay_ms), .awake) catch {
            cause.* = error.ConnectionResetByPeer;
            return error.ConnectionFailed;
        };
        if (next.status == 0) {
            cause.* = error.ConnectionRefused;
            return error.ConnectionFailed;
        }
        out.writeAll(next.body) catch return error.OutOfMemory;
        return .{ .status = @enumFromInt(next.status), .retry_after_ms = next.retry_after_ms };
    }

    fn client(self: *Mock, gpa: Allocator) !Client {
        var c = try init(gpa, testing.io, .{ .api_key = "k", .base_url = "https://example.test/", .retry = .{ .initial_delay_ms = 0 }, .timeout = .fromMilliseconds(500) });
        c.transport = .{ .ctx = self, .sendFn = reply };
        return c;
    }
};

const Team = enum { billing, technical, sales };
const test_questions = .{
    .urgent = question.noul("Needs attention today?"),
    .team = question.choice(Team, "Which team?", .{}),
    .severity = question.score(enum { minor, degraded, outage }, "How severe?", .{ .minor = "a", .degraded = "b", .outage = "c" }),
};

test ask {
    var mock: Mock = .{ .replies = &.{
        .{ .status = 0 },
        .{ .status = 529, .body = "busy", .retry_after_ms = 1 },
        .{ .status = 200, .body = wire.response_fixture },
    } };
    var c = try mock.client(testing.allocator);
    defer c.deinit();
    var d: Diagnostics = .{};
    const r = try c.ask("Charged twice", test_questions, .{ .diagnostics = &d });
    try testing.expectEqual(.billing, r.answers.team.choice);
    try testing.expectEqual(.ok, d.status.?);
    try testing.expectEqual(3, d.attempts);
}

test "ask stops on a non-retryable status" {
    var mock: Mock = .{ .replies = &.{.{ .status = 401, .body = "{\"detail\":\"bad key\"}" }} };
    var c = try mock.client(testing.allocator);
    defer c.deinit();
    var d: Diagnostics = .{};
    try testing.expectError(error.Unauthorized, c.ask("x", test_questions, .{ .diagnostics = &d }));
    try testing.expectEqual(1, mock.calls);
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("http 401 after 1 attempt(s): {\"detail\":\"bad key\"}", try std.fmt.bufPrint(&buf, "{f}", .{d}));
}

test "ask times out an attempt" {
    var mock: Mock = .{ .replies = &.{ .{ .status = 200, .delay_ms = 200 }, .{ .status = 200, .body = wire.response_fixture } } };
    var c = try mock.client(testing.allocator);
    defer c.deinit();
    c.timeout = .fromMilliseconds(10);
    var d: Diagnostics = .{};
    _ = try c.ask("x", test_questions, .{ .diagnostics = &d });
    try testing.expectEqual(2, d.attempts);
    c.retry = .disabled;
    mock.calls = 0;
    try testing.expectError(error.Timeout, c.ask("x", test_questions, .{ .diagnostics = &d }));
    try testing.expectEqual(error.Timeout, d.cause.?);
}

test "ask retries up to the maximum" {
    var mock: Mock = .{ .replies = &.{.{ .status = 0 }} };
    var c = try mock.client(testing.allocator);
    defer c.deinit();
    c.retry = .{ .max_retries = 255, .initial_delay_ms = 0 };
    var d: Diagnostics = .{};
    try testing.expectError(error.ConnectionFailed, c.ask("x", test_questions, .{ .diagnostics = &d }));
    try testing.expectEqual(256, mock.calls);
    try testing.expectEqual(256, d.attempts);
}

test "ask survives allocation failure" {
    var mock: Mock = .{ .replies = &.{.{ .status = 200, .body = wire.response_fixture }} };
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(gpa: Allocator, m: *Mock) !void {
            m.calls = 0;
            var c = try m.client(gpa);
            defer c.deinit();
            _ = try c.ask("x", test_questions, .{});
        }
    }.run, .{&mock});
}

test "init rejects bad configuration" {
    try testing.expectError(error.InvalidBaseUrl, init(testing.allocator, testing.io, .{ .api_key = "k", .base_url = "ftp://x" }));
    try testing.expectError(error.InvalidApiKey, init(testing.allocator, testing.io, .{ .api_key = "k\r\nx: y" }));
}
