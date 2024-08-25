const std = @import("std");
const zaudio = @import("zaudio");

const logger = std.log.scoped(.exe);

pub fn main() !void {
    try zaudio.init();
    defer zaudio.deinit();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const stream = try zaudio.Stream.openDefault(allocator, .{});
    defer stream.close();

    const buffer = try allocator.alloc(f32, 2056);
    defer allocator.free(buffer);

    var phase: f32 = 0;
    const samp_rate: f32 = @floatCast(stream.opts.sample_rate);

    try stream.start();

    for (0..100) |i| {
        logger.debug("Dumping buffer: {d}", .{i});
        for (buffer) |*o| {
            const x = 2 * std.math.pi * phase / samp_rate;
            if (i > 20) {
                o.* =
                    0.1 * std.math.sin(x * 220) +
                    0.1 * std.math.sin(x * 293.66) +
                    0.1 * std.math.sin(x * 349.23);
            } else {
                o.* = 0.2 * std.math.sin(x * 220);
            }
            phase += 1;
        }
        try stream.write(buffer);
    }

    logger.debug("All data written", .{});
    logger.debug("Exit", .{});

    try stream.stop();
}
