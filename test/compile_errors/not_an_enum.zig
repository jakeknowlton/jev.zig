const jev = @import("jev");
comptime {
    _ = jev.choice(u8, "?", .{});
}
