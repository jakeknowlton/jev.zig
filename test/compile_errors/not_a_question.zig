const jev = @import("jev");
comptime {
    _ = @sizeOf(jev.Result(@TypeOf(.{ .x = 1 })));
}
