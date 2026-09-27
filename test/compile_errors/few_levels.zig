const jev = @import("jev");
comptime {
    _ = jev.score(enum { a }, "?", .{ .a = "x" });
}
