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
            retry_after_ms = (std.fmt.parseInt(u64, h.value, 10) catch continue) * 1000;
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
