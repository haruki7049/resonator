# resonator
Voice-routing structures in Zig

Instrument string-to-track (voice lane) mapping, canon voice routing, and Single String Model scheduling of
note onsets with equal-power micro-fades. Depends only on `std` and
[`phrases`](https://github.com/haruki7049/phrases) (`Position`, `TimeSignature`, `Pitch`, ...). Requires Zig `0.16.0`.

The structures do not hold audio: they decide *which lane* a note goes to and *which frames* of it sound, so
any renderer (for example one built on [`lightmix`](https://github.com/haruki7049/lightmix)) can apply the
result to its own sample buffers.

## Provided types

| Symbol | Description |
| :--- | :--- |
| `Instrument` | Multi-string instrument: `name` and one track index per string, with `stringCount` and `getTrackIndex` (`error.InvalidStringIndex` when out of range) |
| `Stagger.VoiceConfig(T)` | Canon voice: `bar_offset`, `beat_offset`, `semitones`, `octaves`, `string_index`, `volume`, with `totalSemitones`, `offsetPosition`, `eql`, `eqlAll` |
| `VoiceScheduler(T)` | Single String Model scheduler for one voice lane: `schedule` turns `Onset`s (`position` + `frames`) into `ScheduledEvent`s (start frame, truncated `active_frames`, release / attack micro-fade bounds); `computeGain` evaluates the equal-power `sin` / `cos` fade curves |
| `phrases` | Re-export of the `phrases` package |

### Single String Model

Each track (or instrument string) is a monophonic voice lane. When a note starts before the previous note on
the same lane has finished, the previous note is cut `fade_frames` after the new onset with an equal-power
`cos` release, and the new note fades in with a `sin` attack (unless `enable_attack_fade` is `false`, e.g. for
percussion). Notes on different lanes never truncate each other, so chords are played on separate strings.

## Usage

```sh
zig fetch --save git+https://github.com/haruki7049/resonator
```

```zig
// build.zig
const resonator = b.dependency("resonator", .{ .target = target, .optimize = optimize });
mod.addImport("resonator", resonator.module("resonator"));
```

```zig
const std = @import("std");
const resonator = @import("resonator");

const Scheduler = resonator.VoiceScheduler(f64);

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    // A 6-string guitar whose strings live on tracks 0..5.
    const indices = try allocator.alloc(usize, 6);
    for (indices, 0..) |*index, i| index.* = i;
    var guitar = resonator.Instrument.init("AcousticGuitar", indices);
    defer guitar.deinit(allocator);
    const track = try guitar.getTrackIndex(2);
    _ = track;

    // Two notes on one string: the first is cut when the second starts.
    const onsets = [_]Scheduler.Onset{
        .{ .position = .{ .bar = 0, .beat = 0.0 }, .frames = 88200 },
        .{ .position = .{ .bar = 0, .beat = 1.0 }, .frames = 44100 },
    };
    // 60 BPM, 4/4, 44100 Hz, 220-frame (5 ms) micro-fades
    const scheduled = try Scheduler.schedule(allocator, &onsets, 60, .{}, 44100, 220, true);
    defer allocator.free(scheduled);

    for (scheduled) |se| {
        for (0..se.active_frames) |frame| {
            const gain = Scheduler.computeGain(se, frame);
            // mix sample (se.start_frame + frame) of onsets[se.event_index] scaled by `gain`
            _ = gain;
        }
    }
}
```

## Development

```sh
zig build test
```

## License

Licensed under either of [Apache License, Version 2.0](LICENSE-APACHE) or [MIT license](LICENSE-MIT) at your option.
