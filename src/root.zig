//! Zig client for TypeSafe's System One API (the Jev model).
const std = @import("std");

pub const Client = @import("Client.zig");
pub const Retry = @import("Retry.zig");
pub const Diagnostics = @import("Diagnostics.zig");
pub const Error = Client.Error;

const question = @import("question.zig");
pub const noul = question.noul;
pub const choice = question.choice;
pub const score = question.score;
pub const RawJson = question.RawJson;

const answer = @import("answer.zig");
pub const NoulAnswer = answer.Noul;
pub const ChoiceAnswer = answer.Choice;
pub const ScoreAnswer = answer.Score;
pub const Result = answer.Result;
pub const Usage = answer.Usage;

test {
    std.testing.refAllDecls(@This());
    _ = @import("wire.zig");
    _ = @import("transport.zig");
}
