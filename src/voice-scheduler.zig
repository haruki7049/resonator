//! Voice lane priority scheduling, overlap detection, and micro-fade curve boundary calculation.
//!
//! Single String Model & Micro-Fade Architecture:
//! 1. Timeline Scheduling: Converts onset musical positions (bar/beat) into absolute sample frame offsets,
//!    sorting a lane's onsets in chronological order.
//! 2. Voice Collision & Truncation: Implements the Single String Model where a single track or instrument
//!    string represents a monophonic voice lane. If a subsequent note triggers before the current note
//!    finishes, `VoiceScheduler` truncates `active_frames` of the preceding note.
//! 3. Equal-Power Micro-Fades: Calculates equal-power release micro-fades (`cos` curve) on truncated
//!    note tails and equal-power attack micro-fades (`sin` curve) on interrupting note onsets,
//!    eliminating click transients and DC discontinuities during rapid note transitions.
//!    `computeGain` evaluates those curves for a frame of a scheduled event.
//!
//! The scheduler only needs each onset's position and length in frames, so it is independent of
//! how the audio itself is stored or rendered.

const std = @import("std");
const phrases = @import("phrases");
const Position = phrases.Position;
const TimeSignature = phrases.TimeSignature;

/// Returns a VoiceScheduler type parameterized by sample floating-point type T.
pub fn inner(comptime T: type) type {
    return struct {
        /// A note onset on a single voice lane: where it starts and how many frames it lasts untruncated.
        pub const Onset = struct {
            position: Position,
            frames: usize,
        };

        /// Scheduled event metadata defining truncated frame bounds and micro-fade curve offsets.
        /// `event_index` is the index of the originating onset in the slice passed to `schedule`.
        pub const ScheduledEvent = struct {
            event_index: usize,
            start_frame: usize,
            active_frames: usize,
            fade_start_offset: usize,
            actual_fade_len: usize,
            has_fade: bool,
            has_attack_fade: bool,
            attack_fade_len: usize,
        };

        const Entry = struct {
            start_frame: usize,
            wave_frames: usize,
            event_index: usize,
            active_frames: usize = 0,
            fade_start_offset: usize = 0,
            actual_fade_len: usize = 0,
            has_fade: bool = false,
            has_attack_fade: bool = false,
            attack_fade_len: usize = 0,
        };

        /// Analyzes the onsets of one voice lane and computes onset frames, overlap truncations,
        /// and micro-fade schedules. The result is sorted by `start_frame` (ties keep input order).
        ///
        /// The caller owns the returned slice and frees it with `allocator.free`.
        /// An empty `onsets` slice returns an empty, unallocated slice.
        pub fn schedule(
            allocator: std.mem.Allocator,
            onsets: []const Onset,
            bpm: usize,
            time_signature: TimeSignature,
            sample_rate: u32,
            fade_frames: usize,
            enable_attack_fade: bool,
        ) ![]ScheduledEvent {
            if (onsets.len == 0) {
                return &[_]ScheduledEvent{};
            }

            var entries = try allocator.alloc(Entry, onsets.len);
            defer allocator.free(entries);

            for (onsets, 0..) |onset, idx| {
                const sf = try onset.position.toSampleOffset(bpm, time_signature, sample_rate);
                entries[idx] = .{
                    .start_frame = sf,
                    .wave_frames = onset.frames,
                    .event_index = idx,
                };
            }

            const sortFn = struct {
                fn lessThan(_: void, a: Entry, b: Entry) bool {
                    if (a.start_frame == b.start_frame) {
                        return a.event_index < b.event_index;
                    }
                    return a.start_frame < b.start_frame;
                }
            }.lessThan;
            std.mem.sort(Entry, entries, {}, sortFn);

            for (entries, 0..) |*entry, i| {
                const sf = entry.start_frame;
                const wf = entry.wave_frames;

                var active_frames = wf;
                var has_fade = false;
                var fade_start_offset: usize = wf;

                if (i + 1 < entries.len) {
                    const next_sf = entries[i + 1].start_frame;
                    if (next_sf <= sf) {
                        // Superseded by subsequent event at the same start frame
                        active_frames = 0;
                    } else if (next_sf < sf + wf) {
                        const overlap_offset = next_sf - sf;
                        fade_start_offset = overlap_offset;
                        const remaining = wf - overlap_offset;
                        var actual_fade = @min(fade_frames, remaining);

                        // Clamp fade if note i+2 starts before this fade finishes
                        if (i + 2 < entries.len) {
                            const next_next_sf = entries[i + 2].start_frame;
                            if (next_sf + actual_fade > next_next_sf) {
                                actual_fade = if (next_next_sf > next_sf) (next_next_sf - next_sf) else 0;
                            }
                        }

                        active_frames = overlap_offset + actual_fade;
                        has_fade = (actual_fade > 0);
                    }
                }

                entry.active_frames = active_frames;
                entry.fade_start_offset = fade_start_offset;
                entry.actual_fade_len = if (has_fade) (active_frames - fade_start_offset) else 0;
                entry.has_fade = has_fade;

                if (enable_attack_fade and active_frames > 0 and i > 0) {
                    var k: usize = i;
                    while (k > 0) {
                        k -= 1;
                        const prev_active = entries[k].active_frames;
                        if (prev_active > 0) {
                            const prev_end = entries[k].start_frame + prev_active;
                            if (prev_end > sf and sf > entries[k].start_frame) {
                                entry.has_attack_fade = true;
                                entry.attack_fade_len = @min(fade_frames, active_frames);
                            }
                            break;
                        }
                    }
                }
            }

            var result = try allocator.alloc(ScheduledEvent, entries.len);
            for (entries, 0..) |e, i| {
                result[i] = .{
                    .event_index = e.event_index,
                    .start_frame = e.start_frame,
                    .active_frames = e.active_frames,
                    .fade_start_offset = e.fade_start_offset,
                    .actual_fade_len = e.actual_fade_len,
                    .has_fade = e.has_fade,
                    .has_attack_fade = e.has_attack_fade,
                    .attack_fade_len = e.attack_fade_len,
                };
            }
            return result;
        }

        /// Computes equal-power micro-fade gain (`sin`/`cos` curve) for a specific frame index within a scheduled event.
        pub fn computeGain(se: ScheduledEvent, frame_idx: usize) T {
            var gain: T = 1.0;
            if (se.has_attack_fade and frame_idx < se.attack_fade_len and se.attack_fade_len > 0) {
                const attack_progress = @as(f64, @floatFromInt(frame_idx + 1)) / @as(f64, @floatFromInt(se.attack_fade_len));
                gain *= @as(T, @floatCast(@sin(attack_progress * (std.math.pi / 2.0))));
            }
            if (se.has_fade and frame_idx >= se.fade_start_offset and se.actual_fade_len > 0) {
                const fade_idx = frame_idx - se.fade_start_offset;
                const progress = @as(f64, @floatFromInt(fade_idx + 1)) / @as(f64, @floatFromInt(se.actual_fade_len));
                gain *= @as(T, @floatCast(@cos(progress * (std.math.pi / 2.0))));
            }
            return gain;
        }
    };
}

const Scheduler = inner(f64);

// 60 BPM at 44100 Hz: one beat is 44100 frames; 220 frames is the 5 ms micro-fade.
const BPM: usize = 60;
const SAMPLE_RATE: u32 = 44100;
const FADE_FRAMES: usize = 220;

fn scheduleTest(onsets: []const Scheduler.Onset, enable_attack_fade: bool) ![]Scheduler.ScheduledEvent {
    return Scheduler.schedule(std.testing.allocator, onsets, BPM, .{}, SAMPLE_RATE, FADE_FRAMES, enable_attack_fade);
}

test "VoiceScheduler resolves single string truncation and micro-fade windows" {
    const scheduled = try scheduleTest(&.{
        .{ .position = .{ .bar = 0, .beat = 0.0 }, .frames = 44100 * 2 },
        .{ .position = .{ .bar = 0, .beat = 1.0 }, .frames = 44100 }, // starts at frame 44100
    }, true);
    defer std.testing.allocator.free(scheduled);

    try std.testing.expectEqual(@as(usize, 2), scheduled.len);

    // Note 1: start_frame 0, truncated at 44100 + 220 = 44320
    try std.testing.expectEqual(@as(usize, 0), scheduled[0].start_frame);
    try std.testing.expectEqual(@as(usize, 44320), scheduled[0].active_frames);
    try std.testing.expect(scheduled[0].has_fade);
    try std.testing.expectEqual(@as(usize, 44100), scheduled[0].fade_start_offset);
    try std.testing.expectEqual(@as(usize, 220), scheduled[0].actual_fade_len);

    // Note 2: start_frame 44100, full duration 44100, has attack fade
    try std.testing.expectEqual(@as(usize, 44100), scheduled[1].start_frame);
    try std.testing.expectEqual(@as(usize, 44100), scheduled[1].active_frames);
    try std.testing.expect(scheduled[1].has_attack_fade);
    try std.testing.expectEqual(@as(usize, 220), scheduled[1].attack_fade_len);
}

test "VoiceScheduler honors enable_attack_fade = false" {
    const scheduled = try scheduleTest(&.{
        .{ .position = .{ .bar = 0, .beat = 0.0 }, .frames = 44100 * 2 },
        .{ .position = .{ .bar = 0, .beat = 1.0 }, .frames = 44100 },
    }, false);
    defer std.testing.allocator.free(scheduled);

    try std.testing.expectEqual(@as(usize, 2), scheduled.len);
    // The release fade of the interrupted note is still applied.
    try std.testing.expect(scheduled[0].has_fade);
    try std.testing.expect(!scheduled[1].has_attack_fade);
    try std.testing.expectEqual(@as(usize, 0), scheduled[1].attack_fade_len);
}

test "VoiceScheduler empty onsets returns an empty schedule" {
    const scheduled = try scheduleTest(&.{}, true);
    defer std.testing.allocator.free(scheduled);

    try std.testing.expectEqual(@as(usize, 0), scheduled.len);
}

test "VoiceScheduler sorts onsets chronologically and keeps event_index" {
    const scheduled = try scheduleTest(&.{
        .{ .position = .{ .bar = 0, .beat = 2.0 }, .frames = 100 },
        .{ .position = .{ .bar = 0, .beat = 0.0 }, .frames = 100 },
        .{ .position = .{ .bar = 0, .beat = 1.0 }, .frames = 100 },
    }, true);
    defer std.testing.allocator.free(scheduled);

    try std.testing.expectEqual(@as(usize, 3), scheduled.len);
    try std.testing.expectEqual(@as(usize, 1), scheduled[0].event_index);
    try std.testing.expectEqual(@as(usize, 0), scheduled[0].start_frame);
    try std.testing.expectEqual(@as(usize, 2), scheduled[1].event_index);
    try std.testing.expectEqual(@as(usize, 44100), scheduled[1].start_frame);
    try std.testing.expectEqual(@as(usize, 0), scheduled[2].event_index);
    try std.testing.expectEqual(@as(usize, 88200), scheduled[2].start_frame);
}

test "VoiceScheduler cascades voice priority across three overlapping notes" {
    const scheduled = try scheduleTest(&.{
        .{ .position = .{ .bar = 0, .beat = 0.0 }, .frames = 44100 * 4 },
        .{ .position = .{ .bar = 0, .beat = 1.0 }, .frames = 44100 * 3 },
        .{ .position = .{ .bar = 0, .beat = 2.0 }, .frames = 44100 * 2 },
    }, true);
    defer std.testing.allocator.free(scheduled);

    // Note 1 is cut 220 frames after note 2 starts, note 2 is cut 220 frames after note 3 starts.
    try std.testing.expectEqual(@as(usize, 44320), scheduled[0].active_frames);
    try std.testing.expectEqual(@as(usize, 44100), scheduled[1].start_frame);
    try std.testing.expectEqual(@as(usize, 44320), scheduled[1].active_frames);
    try std.testing.expect(scheduled[1].has_attack_fade);
    try std.testing.expectEqual(@as(usize, 88200), scheduled[2].start_frame);
    try std.testing.expectEqual(@as(usize, 88200), scheduled[2].active_frames);
    try std.testing.expect(!scheduled[2].has_fade);
    try std.testing.expect(scheduled[2].has_attack_fade);
}

test "VoiceScheduler same timestamp collision supersedes earlier note" {
    const scheduled = try scheduleTest(&.{
        .{ .position = .{ .bar = 0, .beat = 0.0 }, .frames = 44100 },
        .{ .position = .{ .bar = 0, .beat = 0.0 }, .frames = 44100 },
    }, true);
    defer std.testing.allocator.free(scheduled);

    try std.testing.expectEqual(@as(usize, 0), scheduled[0].event_index);
    try std.testing.expectEqual(@as(usize, 0), scheduled[0].active_frames);
    try std.testing.expectEqual(@as(usize, 1), scheduled[1].event_index);
    try std.testing.expectEqual(@as(usize, 44100), scheduled[1].active_frames);
    // The silenced note does not count as an interrupted voice.
    try std.testing.expect(!scheduled[1].has_attack_fade);
}

test "VoiceScheduler notes separated by silence play full duration without fade" {
    const scheduled = try scheduleTest(&.{
        .{ .position = .{ .bar = 0, .beat = 0.0 }, .frames = 44100 }, // 0s - 1s
        .{ .position = .{ .bar = 0, .beat = 2.0 }, .frames = 44100 }, // 2s - 3s (1s gap)
    }, true);
    defer std.testing.allocator.free(scheduled);

    for (scheduled) |se| {
        try std.testing.expectEqual(@as(usize, 44100), se.active_frames);
        try std.testing.expect(!se.has_fade);
        try std.testing.expect(!se.has_attack_fade);
    }
}

test "VoiceScheduler note shorter than fade window does not underflow" {
    const second: Position = .{ .bar = 0, .beat = 20.0 / 44100.0 };
    const second_frame = try second.toSampleOffset(BPM, .{}, SAMPLE_RATE);

    const scheduled = try scheduleTest(&.{
        .{ .position = .{ .bar = 0, .beat = 0.0 }, .frames = 50 },
        .{ .position = second, .frames = 44100 },
    }, true);
    defer std.testing.allocator.free(scheduled);

    // The release fade is limited to the 50-frame note's remaining frames.
    try std.testing.expectEqual(@as(usize, 50), scheduled[0].active_frames);
    try std.testing.expectEqual(second_frame, scheduled[0].fade_start_offset);
    try std.testing.expectEqual(50 - second_frame, scheduled[0].actual_fade_len);
}

test "VoiceScheduler clamps preceding micro-fade before a third rapid note" {
    const second: Position = .{ .bar = 0, .beat = 50.0 / 44100.0 };
    const third: Position = .{ .bar = 0, .beat = 80.0 / 44100.0 };
    const second_frame = try second.toSampleOffset(BPM, .{}, SAMPLE_RATE);
    const third_frame = try third.toSampleOffset(BPM, .{}, SAMPLE_RATE);

    const scheduled = try scheduleTest(&.{
        .{ .position = .{ .bar = 0, .beat = 0.0 }, .frames = 44100 },
        .{ .position = second, .frames = 44100 },
        .{ .position = third, .frames = 44100 },
    }, true);
    defer std.testing.allocator.free(scheduled);

    // Note 1's fade cannot extend past the onset of note 3.
    try std.testing.expectEqual(third_frame, scheduled[0].active_frames);
    try std.testing.expectEqual(third_frame - second_frame, scheduled[0].actual_fade_len);
    // Note 2 gets the full 220-frame fade once note 3 starts.
    try std.testing.expectEqual(third_frame - second_frame + 220, scheduled[1].active_frames);
    try std.testing.expectEqual(@as(usize, 220), scheduled[1].actual_fade_len);
}

test "VoiceScheduler truncation shortens the lane end frame" {
    const scheduled = try scheduleTest(&.{
        .{ .position = .{ .bar = 0, .beat = 0.0 }, .frames = 44100 * 10 },
        .{ .position = .{ .bar = 0, .beat = 1.0 }, .frames = 44100 },
    }, true);
    defer std.testing.allocator.free(scheduled);

    var max_frame_end: usize = 0;
    for (scheduled) |se| {
        if (se.active_frames > 0) max_frame_end = @max(max_frame_end, se.start_frame + se.active_frames);
    }
    // Ends with note 2 at 2.0 s, not with the untruncated 10 s note 1.
    try std.testing.expectEqual(@as(usize, 88200), max_frame_end);
}

test "VoiceScheduler invalid position returns error.InvalidPosition without leaking" {
    try std.testing.expectError(error.InvalidPosition, scheduleTest(&.{
        .{ .position = .{ .bar = 0, .beat = 0.0 }, .frames = 100 },
        .{ .position = .{ .bar = 0, .beat = -1.0 }, .frames = 100 },
    }, true));
}

test "VoiceScheduler computeGain with no fades returns 1.0" {
    const se: Scheduler.ScheduledEvent = .{
        .event_index = 0,
        .start_frame = 0,
        .active_frames = 100,
        .fade_start_offset = 100,
        .actual_fade_len = 0,
        .has_fade = false,
        .has_attack_fade = false,
        .attack_fade_len = 0,
    };

    try std.testing.expectApproxEqAbs(@as(f64, 1.0), Scheduler.computeGain(se, 0), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), Scheduler.computeGain(se, 50), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), Scheduler.computeGain(se, 99), 0.0001);
}

test "VoiceScheduler computeGain with attack fade follows sine curve" {
    const se: Scheduler.ScheduledEvent = .{
        .event_index = 0,
        .start_frame = 0,
        .active_frames = 100,
        .fade_start_offset = 100,
        .actual_fade_len = 0,
        .has_fade = false,
        .has_attack_fade = true,
        .attack_fade_len = 100,
    };

    // frame 0: (1/100) * pi/2 => sin
    const expected_start = @sin(1.0 / 100.0 * (std.math.pi / 2.0));
    try std.testing.expectApproxEqAbs(expected_start, Scheduler.computeGain(se, 0), 0.0001);

    // frame 99: (100/100) * pi/2 = pi/2 => sin = 1.0
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), Scheduler.computeGain(se, 99), 0.0001);
}

test "VoiceScheduler computeGain with decay fade follows cosine curve" {
    const se: Scheduler.ScheduledEvent = .{
        .event_index = 0,
        .start_frame = 0,
        .active_frames = 100,
        .fade_start_offset = 80,
        .actual_fade_len = 20,
        .has_fade = true,
        .has_attack_fade = false,
        .attack_fade_len = 0,
    };

    // Before fade start: gain = 1.0
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), Scheduler.computeGain(se, 79), 0.0001);

    // At fade start (frame 80): (1/20) * pi/2 => cos
    const expected_fade_start = @cos(1.0 / 20.0 * (std.math.pi / 2.0));
    try std.testing.expectApproxEqAbs(expected_fade_start, Scheduler.computeGain(se, 80), 0.0001);

    // At final fade frame (frame 99): (20/20) * pi/2 => cos(pi/2) = 0.0
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), Scheduler.computeGain(se, 99), 0.0001);
}

test "VoiceScheduler computeGain crossfade at the midpoint is equal-power" {
    const scheduled = try scheduleTest(&.{
        .{ .position = .{ .bar = 0, .beat = 0.0 }, .frames = 44100 * 2 },
        .{ .position = .{ .bar = 0, .beat = 1.0 }, .frames = 44100 },
    }, true);
    defer std.testing.allocator.free(scheduled);

    // 110 frames into the 220-frame crossfade, both curves are near pi/4 (gain ~0.7071, not linear 0.5).
    const release = Scheduler.computeGain(scheduled[0], 44100 + 110);
    const attack = Scheduler.computeGain(scheduled[1], 110);
    try std.testing.expectApproxEqAbs(@as(f64, 0.7071), release, 0.01);
    try std.testing.expectApproxEqAbs(@as(f64, 0.7071), attack, 0.01);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), release * release + attack * attack, 0.02);
}

test {
    std.testing.refAllDecls(@This());
}
