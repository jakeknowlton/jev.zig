const std = @import("std");
const jev = @import("jev");

const Team = enum { billing, technical, sales };
const Severity = enum { minor, degraded, outage };

pub fn main(init: std.process.Init) !void {
    const api_key = init.environ_map.get("TYPESAFE_API_KEY") orelse return error.MissingApiKey;

    var client: jev.Client = try .init(init.gpa, init.io, .{ .api_key = api_key });
    defer client.deinit();

    const r = try client.ask("I was charged twice and now I can't log in.", .{
        .urgent = jev.noul("Does this need attention today?"),
        .team = jev.choice(Team, "Which team should handle this?", .{
            .billing = "Charges, invoices and refunds",
            .technical = "Bugs, outages and integrations",
        }),
        .severity = jev.score(Severity, "How severe is the impact?", .{
            .minor = "Cosmetic or affects one user",
            .degraded = "A feature is broken but there is a workaround",
            .outage = "The service cannot be used",
        }),
    }, .{});

    if (r.answers.urgent.probability > 0.8) std.debug.print("page the on-call\n", .{});
    switch (r.answers.team.choice) {
        .billing => std.debug.print("route to billing\n", .{}),
        .technical => std.debug.print("route to engineering\n", .{}),
        .sales => std.debug.print("route to sales\n", .{}),
    }
    std.debug.print("severity {d:.2} of 2\n", .{r.answers.severity.score});
}
