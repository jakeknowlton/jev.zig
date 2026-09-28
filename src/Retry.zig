//! Backoff policy for connection errors, 429, 529 and 5xx.
const std = @import("std");
const Retry = @This();

max_retries: u8 = 2,
initial_delay_ms: u64 = 500,
max_delay_ms: u64 = 5_000,
/// Cap for a server `Retry-After`.
max_retry_after_ms: u64 = 30_000,

pub const disabled: Retry = .{ .max_retries = 0 };

/// Delay before retry number `attempt` (0-based). `jitter` is uniform in [0, 1).
pub fn delayMs(self: Retry, attempt: u16, retry_after_ms: ?u64, jitter: f64) u64 {
    if (retry_after_ms) |ms| return @min(ms, self.max_retry_after_ms, std.math.maxInt(i64));
    const base = @min(self.initial_delay_ms <<| @min(attempt, 63), self.max_delay_ms);
    return @intFromFloat(@as(f64, @floatFromInt(base)) * (0.75 + jitter / 2));
}

test delayMs {
    const r: Retry = .{};
    try std.testing.expectEqual(500, r.delayMs(0, null, 0.5));
    try std.testing.expectEqual(2000, r.delayMs(2, null, 0.5));
    try std.testing.expectEqual(5000, r.delayMs(9, null, 0.5));
    try std.testing.expectEqual(375, r.delayMs(0, null, 0));
    try std.testing.expectEqual(30_000, r.delayMs(0, 120_000, 0.5));
    const uncapped: Retry = .{ .max_retry_after_ms = std.math.maxInt(u64) };
    try std.testing.expect(uncapped.delayMs(0, std.math.maxInt(u64), 0.5) <= std.math.maxInt(i64));
}
