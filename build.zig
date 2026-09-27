const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("jev", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = mod })).step);

    const compile_errors = b.step("compile-errors", "Check that invalid questions are rejected");
    test_step.dependOn(compile_errors);
    for (rejected) |case| {
        const object = b.addObject(.{ .name = case.name, .root_module = b.createModule(.{
            .root_source_file = b.path(b.fmt("test/compile_errors/{s}.zig", .{case.name})),
            .target = target,
            .imports = &.{.{ .name = "jev", .module = mod }},
        }) });
        object.expect_errors = .{ .contains = case.message };
        compile_errors.dependOn(&object.step);
    }

    const examples = b.step("examples", "Build the examples");
    const triage = b.addExecutable(.{ .name = "triage", .root_module = b.createModule(.{
        .root_source_file = b.path("examples/triage.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "jev", .module = mod }},
    }) });
    examples.dependOn(&b.addInstallArtifact(triage, .{}).step);
}

/// Each file must fail to compile with an error line ending in `message`.
const rejected = [_]struct { name: []const u8, message: []const u8 }{
    .{ .name = "not_a_question", .message = "question 'x' must be built with jev.noul, jev.choice or jev.score" },
    .{ .name = "not_an_enum", .message = "must be an exhaustive enum for choice" },
    .{ .name = "unknown_tag", .message = "has no tag 'b'" },
    .{ .name = "few_levels", .message = "has 1 tags but score needs 2 to 10" },
    .{ .name = "missing_level", .message = "score level 'b' needs a description" },
    .{ .name = "bool_content", .message = "but must be a string, struct, tuple or slice" },
};
