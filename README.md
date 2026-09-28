# jev.zig

An unofficial Zig client for TypeSafe's [System One API](https://docs.typesafe.ai) and its Jev model.

- Noul, Choice and Score questions
- Answer types derived from the questions at compile time
- Retries with backoff
- Standard library only

## Example

```zig
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
```

A misspelled option, a score with one level, or a field that is not a question
is a compile error. This program is [examples/triage.zig](examples/triage.zig).

## Requirements

Zig 0.16.0.

## Installation

Add jev.zig to your `build.zig.zon`:

```sh
zig fetch --save git+https://github.com/jakeknowlton/jev.zig#v0.1.0
```

Then add the module in `build.zig`:

```zig
const jev = b.dependency("jev", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("jev", jev.module("jev"));
```

## Usage

| Question | Answer |
| --- | --- |
| `jev.noul(instructions)` | `probability` of yes |
| `jev.choice(Enum, instructions, descriptions)` | `choice` as your enum, `probabilities` per tag, `confidence` |
| `jev.score(Enum, instructions, descriptions)` | `score` as a weighted level index, `probabilities` per tag, `confidence`, `likeliest()` |

A Noul can describe its two outcomes with `.criteria(yes, no)`. A Choice may
describe any subset of its tags. A Score must describe every tag, in
declaration order from low to high.

`state`, instructions and descriptions accept a string or any value that
`std.json` can write, such as a struct literal. `jev.RawJson` passes
pre-encoded JSON through as is.

The result owns no memory. `r.usage` and `r.model()` report the token counts
and the model that answered.

The model defaults to `jev-latest`. Set `.model` in the client options or in
the options of a single `ask` to pin a version.

## Errors

HTTP statuses map to `Unauthorized`, `InvalidRequest`, `RateLimited`,
`Overloaded` and `ServerError`. Connection failures, cancellation and a
malformed reply have their own members of `jev.Error`.

For the status, the attempt count and the start of the response body, pass a
`jev.Diagnostics`:

```zig
var diagnostics: jev.Diagnostics = .{};
const r = client.ask(state, questions, .{ .diagnostics = &diagnostics }) catch |err| {
    std.log.err("{t}: {f}", .{ err, diagnostics });
    return err;
};
```

## Retries

Connection failures, timeouts, 429, 529 and 5xx are retried twice with
exponential backoff and jitter. A server `Retry-After` is honored. TLS
failures and malformed replies are reported immediately and not retried. Configure this with
`.retry` in the client options, or pass `.retry = .disabled`.

Set `.timeout` in the client options to bound each attempt. Without it a call
blocks until the server answers or the `Io` cancels it.

## Testing

Point `.base_url` at a local server to test without calling TypeSafe.

## License

[MIT](LICENSE)
