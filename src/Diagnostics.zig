//! Detail about the last HTTP attempt of a call. Each call needs its own.
const std = @import("std");
const Diagnostics = @This();

status: ?std.http.Status = null,
/// Number of HTTP attempts. The first request counts as one.
attempts: u8 = 0,
retry_after_ms: ?u64 = null,
/// The error behind `ConnectionFailed` or `Timeout`.
cause: ?anyerror = null,
body_len: u16 = 0,
body_buf: [512]u8 = undefined,

/// The first bytes of the response body. The cut is on a UTF-8 boundary.
/// After `InvalidResponse` this is the 2xx body that failed to decode.
pub fn body(self: *const Diagnostics) []const u8 {
    return self.body_buf[0..self.body_len];
}

pub fn setBody(self: *Diagnostics, bytes: []const u8) void {
    var len = @min(bytes.len, self.body_buf.len);
    while (len < bytes.len and len > 0 and bytes[len] & 0xC0 == 0x80) len -= 1;
    @memcpy(self.body_buf[0..len], bytes[0..len]);
    self.body_len = @intCast(len);
}

pub fn format(self: *const Diagnostics, w: *std.Io.Writer) std.Io.Writer.Error!void {
    if (self.status) |s| try w.print("http {d}", .{@intFromEnum(s)}) else try w.print("{?t}", .{self.cause});
    try w.print(" after {d} attempt(s)", .{self.attempts});
    if (self.body_len > 0) try w.print(": {s}", .{self.body()});
}
