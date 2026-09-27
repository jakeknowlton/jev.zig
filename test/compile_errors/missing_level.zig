const jev = @import("jev");
comptime {
    _ = jev.score(enum { a, b }, "?", .{ .a = "x" });
}
