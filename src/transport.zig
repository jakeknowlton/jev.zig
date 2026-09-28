//! One HTTP POST behind a vtable. Tests swap in a mock.
const std = @import("std");
const Io = std.Io;

pub const Transport = struct {
    ctx: *anyopaque,
    sendFn: *const fn (ctx: *anyopaque, request: Request, body_out: *Io.Writer, cause: *?anyerror) Error!Response,

    pub const Request = struct {
        uri: std.Uri,
        authorization: []const u8,
        body: []u8,
    };

    pub const Response = struct {
        status: std.http.Status,
        retry_after_ms: ?u64 = null,
    };

    pub const Error = error{ ConnectionFailed, InvalidResponse, Canceled, OutOfMemory };

    /// Largest response body accepted.
    pub const max_body_len = 1 << 20;

    /// `cause` receives the error behind `ConnectionFailed`.
    pub fn send(self: Transport, request: Request, body_out: *Io.Writer, cause: *?anyerror) Error!Response {
        return self.sendFn(self.ctx, request, body_out, cause);
    }

    /// A redirect or a compressed response is a failure, which keeps the bearer
    /// on the configured host.
    pub fn http(client: *std.http.Client) Transport {
        return .{ .ctx = client, .sendFn = httpSend };
    }
};

fn httpSend(ctx: *anyopaque, request: Transport.Request, body_out: *Io.Writer, cause: *?anyerror) Transport.Error!Transport.Response {
    const client: *std.http.Client = @ptrCast(@alignCast(ctx));
    var req = client.request(.POST, request.uri, .{
        .redirect_behavior = .unhandled,
        .headers = .{
            .authorization = .{ .override = request.authorization },
            .content_type = .{ .override = "application/json" },
            .accept_encoding = .{ .override = "identity" },
            .user_agent = .{ .override = "jev.zig" },
        },
        .extra_headers = &.{.{ .name = "accept", .value = "application/json" }},
    }) catch |err| return fail(err, cause);
    defer req.deinit();
    req.accept_encoding = @splat(false);
    req.accept_encoding[@intFromEnum(std.http.ContentEncoding.identity)] = true;
    req.sendBodyComplete(request.body) catch |err| return fail(err, cause);
    var response = req.receiveHead(&.{}) catch |err| return fail(err, cause);

    var retry_after_ms: ?u64 = null;
    var it = response.head.iterateHeaders();
    while (it.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "retry-after-ms")) {
            retry_after_ms = std.fmt.parseInt(u64, h.value, 10) catch continue;
        } else if (std.ascii.eqlIgnoreCase(h.name, "retry-after") and retry_after_ms == null) {
            retry_after_ms = (std.fmt.parseInt(u64, h.value, 10) catch continue) *| 1000;
        }
    }
    const status = response.head.status;

    var transfer_buf: [4096]u8 = undefined;
    var limited = response.reader(&transfer_buf).limited(.limited(Transport.max_body_len + 1), &.{});
    const len = limited.interface.streamRemaining(body_out) catch |err| switch (err) {
        error.ReadFailed => return fail(response.bodyErr() orelse error.ReadFailed, cause),
        error.WriteFailed => return error.OutOfMemory,
    };
    if (len > Transport.max_body_len) return error.InvalidResponse;
    return .{ .status = status, .retry_after_ms = retry_after_ms };
}

fn fail(err: anyerror, cause: *?anyerror) Transport.Error {
    return switch (err) {
        error.OutOfMemory, error.Canceled => |e| e,
        else => {
            cause.* = err;
            return error.ConnectionFailed;
        },
    };
}

const testing = std.testing;

test "http transport" {
    const io = testing.io;
    const address: Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var listener = try address.listen(io, .{});
    defer listener.deinit(io);
    var served = try io.concurrent(serveOnce, .{ &listener, io });
    defer served.cancel(io) catch {};

    var client: std.http.Client = .{ .allocator = testing.allocator, .io = io };
    defer client.deinit();
    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/v1/systemone", .{listener.socket.address.getPort()});
    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var cause: ?anyerror = null;
    var body = "{\"a\":1}".*;
    const response = try Transport.http(&client).send(.{ .uri = try std.Uri.parse(url), .authorization = "Bearer k", .body = &body }, &out.writer, &cause);
    try served.await(io);
    try testing.expectEqual(.too_many_requests, response.status);
    try testing.expectEqual(7, response.retry_after_ms);
    try testing.expectEqualStrings("busy", out.written());
}

fn serveOnce(listener: *Io.net.Server, io: Io) !void {
    const stream = try listener.accept(io);
    defer stream.close(io);
    var read_buf: [4096]u8 = undefined;
    var write_buf: [1024]u8 = undefined;
    var reader = stream.reader(io, &read_buf);
    var writer = stream.writer(io, &write_buf);
    var server: std.http.Server = .init(&reader.interface, &writer.interface);
    var request = try server.receiveHead();
    try testing.expectEqual(.POST, request.head.method);
    try testing.expectEqualStrings("/v1/systemone", request.head.target);
    var authorized = false;
    var it = request.iterateHeaders();
    while (it.next()) |h| if (std.ascii.eqlIgnoreCase(h.name, "authorization")) {
        try testing.expectEqualStrings("Bearer k", h.value);
        authorized = true;
    };
    try testing.expect(authorized);
    var transfer_buf: [64]u8 = undefined;
    var body: [7]u8 = undefined;
    try request.readerExpectNone(&transfer_buf).readSliceAll(&body);
    try testing.expectEqualStrings("{\"a\":1}", &body);
    try request.respond("busy", .{
        .status = .too_many_requests,
        .extra_headers = &.{ .{ .name = "retry-after", .value = "18446744073709551615" }, .{ .name = "retry-after-ms", .value = "7" } },
    });
}
