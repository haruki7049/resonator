//! Voice-routing structures for multi-string instruments.
//!
//! std + `phrases` only: instrument string-to-track (voice lane) mapping and canon voice routing.

const std = @import("std");

/// The `phrases` package this library is built on (`Position`, `TimeSignature`, ...).
pub const phrases = @import("phrases");
/// Multi-string instrument mapping each string to a track (voice lane) index.
pub const Instrument = @import("./instrument.zig");
/// Canon voice routing (`Stagger.VoiceConfig(T)`): position offset, transposition, string index, volume.
pub const Stagger = @import("./stagger.zig");

test {
    std.testing.refAllDecls(@This());
    _ = @import("./instrument.zig");
    _ = @import("./stagger.zig");
}

test "Instrument routes each string of a chord to its own track" {
    const allocator = std.testing.allocator;

    // A 3-string instrument whose strings live on tracks 4, 5 and 6.
    const indices = try allocator.alloc(usize, 3);
    for (indices, 0..) |*index, i| index.* = 4 + i;
    var rhodes = Instrument.init("Rhodes", indices);
    defer rhodes.deinit(allocator);

    var tracks: [3]usize = undefined;
    for (&tracks, 0..) |*track, string| track.* = try rhodes.getTrackIndex(string);
    try std.testing.expectEqualSlices(usize, &.{ 4, 5, 6 }, &tracks);
}

test "Stagger voice routes a phrase note onto an instrument lane" {
    const allocator = std.testing.allocator;
    const Voice = Stagger.VoiceConfig(f64);
    const voice = Voice{ .bar_offset = 2, .beat_offset = 0.5, .semitones = 7, .string_index = 1 };

    const indices = try allocator.alloc(usize, 3);
    for (indices, 0..) |*index, i| index.* = 10 + i;
    var rhodes = Instrument.init("Rhodes", indices);
    defer rhodes.deinit(allocator);

    // A phrase note at bar 1, beat 1.0 on string 2, played by the voice.
    const base: phrases.Position = .{ .bar = 1, .beat = 1.0 };
    const pos = voice.offsetPosition(base);
    try std.testing.expectEqual(@as(usize, 3), pos.bar);
    try std.testing.expectEqual(@as(f64, 1.5), pos.beat);

    // The voice transposes by a fifth, 7 semitones. Applying that to the note's pitch is left to
    // the consumer (for example C4 to G4 with `pitches.TwelveTonePitch.add`).
    try std.testing.expectEqual(@as(isize, 7), voice.totalSemitones());

    // String 2 shifted by the voice's string_index wraps around to string 0.
    const string = (2 + voice.string_index) % rhodes.stringCount();
    try std.testing.expectEqual(@as(usize, 10), try rhodes.getTrackIndex(string));
}
