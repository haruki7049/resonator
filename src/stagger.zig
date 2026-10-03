//! Canon voice configuration specifying position offset, pitch transposition, and routing.

const std = @import("std");
const Position = @import("meters").Position;

/// Configuration for a canon voice entry specifying position offset, pitch transposition, and routing.
pub fn VoiceConfig(comptime T: type) type {
    return struct {
        /// Bar delay offset relative to canon start position.
        bar_offset: usize = 0,
        /// Beat delay offset relative to canon start position.
        beat_offset: f64 = 0.0,
        /// Transposition offset in semitones.
        semitones: isize = 0,
        /// Transposition offset in octaves.
        octaves: isize = 0,
        /// Target instrument string index (for multi-string instruments).
        string_index: usize = 0,
        /// Volume scale factor for this voice.
        volume: T = 1.0,

        const Self = @This();

        /// Returns total semitones of transposition combining semitones and octaves (12 semitones each).
        ///
        /// `resonator` has no pitch type: the consumer applies this amount to its own pitches, for
        /// example with `pitches.TwelveTonePitch.add`.
        pub fn totalSemitones(self: Self) isize {
            return self.semitones + (self.octaves * 12);
        }

        /// Returns whether two voice configurations are equal, comparing floating-point fields within 1e-6.
        pub fn eql(a: Self, b: Self) bool {
            return a.bar_offset == b.bar_offset and
                @abs(a.beat_offset - b.beat_offset) < 1e-6 and
                a.semitones == b.semitones and
                a.octaves == b.octaves and
                a.string_index == b.string_index and
                @abs(a.volume - b.volume) < 1e-6;
        }

        /// Returns whether two voice lists have the same length and pairwise-equal voices.
        pub fn eqlAll(a: []const Self, b: []const Self) bool {
            if (a.len != b.len) return false;
            for (a, b) |va, vb| {
                if (!va.eql(vb)) return false;
            }
            return true;
        }

        /// Computes the offset position given a base position.
        pub fn offsetPosition(self: Self, base: Position) Position {
            return .{
                .bar = base.bar + self.bar_offset,
                .beat = base.beat + self.beat_offset,
            };
        }
    };
}

test "VoiceConfig totalSemitones and offsetPosition combine offsets" {
    const vc = VoiceConfig(f64){
        .bar_offset = 4,
        .beat_offset = 1.5,
        .semitones = 7,
        .octaves = -1,
        .volume = 0.8,
    };

    try std.testing.expectEqual(@as(isize, -5), vc.totalSemitones());

    const base = Position{ .bar = 2, .beat = 0.5 };
    const offset_pos = vc.offsetPosition(base);
    try std.testing.expectEqual(@as(usize, 6), offset_pos.bar);
    try std.testing.expectEqual(@as(f64, 2.0), offset_pos.beat);
}

test "VoiceConfig eql and eqlAll compare voices within tolerance" {
    const Voice = VoiceConfig(f64);
    const a = Voice{ .bar_offset = 1, .string_index = 2, .volume = 0.75 };
    const b = Voice{ .bar_offset = 1, .string_index = 2, .volume = 0.75 + 1e-9 };
    const c = Voice{ .bar_offset = 2, .string_index = 2, .volume = 0.75 };

    try std.testing.expect(a.eql(b));
    try std.testing.expect(!a.eql(c));

    try std.testing.expect(Voice.eqlAll(&.{ a, c }, &.{ b, c }));
    try std.testing.expect(!Voice.eqlAll(&.{ a, c }, &.{a}));
    try std.testing.expect(!Voice.eqlAll(&.{ a, c }, &.{ a, a }));
}

test {
    std.testing.refAllDecls(@This());
}
