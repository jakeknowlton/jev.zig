const jev = @import("jev");
comptime {
    _ = jev.choice(enum { a }, "?", .{ .b = "x" });
}
