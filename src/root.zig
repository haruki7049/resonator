//! Voice-routing structures for multi-string instruments.
//!
//! std + `phrases` only: instrument string-to-track (voice lane) mapping, canon voice routing,
//! and Single String Model scheduling of note onsets with equal-power micro-fades.

const std = @import("std");

/// The `phrases` package this library is built on (`Position`, `TimeSignature`, `tempo`, ...).
pub const phrases = @import("phrases");
/// Multi-string instrument mapping each string to a track (voice lane) index.
pub const Instrument = @import("./instrument.zig");
/// Canon voice routing (`Stagger.VoiceConfig(T)`): position offset, transposition, string index, volume.
pub const Stagger = @import("./stagger.zig");
/// Single String Model scheduler for one voice lane, parameterized by sample type T.
pub const VoiceScheduler = @import("./voice-scheduler.zig").inner;

test {
    std.testing.refAllDecls(@This());
    _ = @import("./instrument.zig");
    _ = @import("./stagger.zig");
    _ = @import("./voice-scheduler.zig");
}

test "Instrument strings are independent voice lanes" {
    const allocator = std.testing.allocator;
    const Scheduler = VoiceScheduler(f64);

    // A 2-string instrument whose strings live on tracks 3 and 4.
    const indices = try allocator.alloc(usize, 2);
    indices[0] = 3;
    indices[1] = 4;
    var guitar = Instrument.init("Guitar", indices);
    defer guitar.deinit(allocator);

    // Per-track onset lists, indexed by track index.
    var lanes: [5]std.ArrayList(Scheduler.Onset) = @splat(.empty);
    defer for (&lanes) |*lane| lane.deinit(allocator);

    // A chord on both strings, then a second note on string 0 while string 1 keeps ringing.
    const notes = [_]struct { string: usize, beat: f64 }{
        .{ .string = 0, .beat = 0.0 },
        .{ .string = 1, .beat = 0.0 },
        .{ .string = 0, .beat = 1.0 },
    };
    for (notes) |n| {
        const track = try guitar.getTrackIndex(n.string);
        try lanes[track].append(allocator, .{ .position = .{ .beat = n.beat }, .frames = 44100 * 2 });
    }

    const string0 = try Scheduler.schedule(allocator, lanes[3].items, 60, .{}, 44100, 220, true);
    defer allocator.free(string0);
    const string1 = try Scheduler.schedule(allocator, lanes[4].items, 60, .{}, 44100, 220, true);
    defer allocator.free(string1);

    // String 0 is monophonic: its first note is cut when its second note starts.
    try std.testing.expectEqual(@as(usize, 2), string0.len);
    try std.testing.expectEqual(@as(usize, 44320), string0[0].active_frames);
    try std.testing.expect(string0[1].has_attack_fade);

    // String 1 is not truncated by string 0 (no cross-lane truncation).
    try std.testing.expectEqual(@as(usize, 1), string1.len);
    try std.testing.expectEqual(@as(usize, 44100 * 2), string1[0].active_frames);
    try std.testing.expect(!string1[0].has_fade);
}

test "Stagger voice routes a phrase note onto an instrument lane" {
    const Voice = Stagger.VoiceConfig(f64);
    const voice = Voice{ .bar_offset = 2, .beat_offset = 0.5, .semitones = 7, .string_index = 1 };

    const base: phrases.Position = .{ .bar = 1, .beat = 1.0 };
    const pos = voice.offsetPosition(base);
    try std.testing.expectEqual(@as(usize, 3), pos.bar);
    try std.testing.expectEqual(@as(f64, 1.5), pos.beat);

    const pitch = (phrases.Pitch{ .code = .c, .octave = 4 }).add(voice.totalSemitones());
    try std.testing.expectEqual(phrases.Pitch{ .code = .g, .octave = 4 }, pitch);
}
