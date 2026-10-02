# resonator

Voice-routing structures in Zig

Instrument string-to-track (voice lane) mapping and canon voice routing. Depends only on `std` and
[`phrases`](https://github.com/haruki7049/phrases) (`Position`, `Pitch`, ...). Requires Zig `0.16.0`.

The structures do not hold audio or schedule it: they decide *which lane* a note goes to and *where and how
transposed* a canon voice plays it. Scheduling and rendering live in a sequencer (for example one built on
[`lightmix`](https://github.com/haruki7049/lightmix)).

## Provided types

| Symbol | Description |
| :--- | :--- |
| `Instrument` | Multi-string instrument: `name` and one track index per string (0-indexed from the lowest string), with `stringCount` and `getTrackIndex` (`error.InvalidStringIndex` when out of range) |
| `Stagger.VoiceConfig(T)` | Canon voice: `bar_offset`, `beat_offset`, `semitones`, `octaves`, `string_index`, `volume` (of type `T`), with `totalSemitones`, `offsetPosition`, `eql`, `eqlAll` |
| `phrases` | Re-export of the `phrases` package |

Each string of an `Instrument` is meant to be its own monophonic voice lane (track), so notes on different
strings ring together while a new note on the same string replaces the previous one.

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

const Voice = resonator.Stagger.VoiceConfig(f64);

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    // A 6-string guitar whose strings live on tracks 0..5 of a sequencer.
    const indices = try allocator.alloc(usize, 6);
    for (indices, 0..) |*index, i| index.* = i;
    var guitar = resonator.Instrument.init("AcousticGuitar", indices);
    defer guitar.deinit(allocator);

    // A canon voice entering one bar later, a fifth up, shifted by one string.
    const voice = Voice{ .bar_offset = 1, .semitones = 7, .string_index = 1, .volume = 0.8 };

    // Route a phrase note (bar 0, beat 1.0, string 2, E4) through the voice.
    const position = voice.offsetPosition(.{ .bar = 0, .beat = 1.0 });
    const pitch = (resonator.phrases.Pitch{ .code = .e, .octave = 4 }).add(voice.totalSemitones());
    const track = try guitar.getTrackIndex((2 + voice.string_index) % guitar.stringCount());

    std.debug.print("track {d}: bar {d} beat {d} {s}{d}\n", .{ track, position.bar, position.beat, @tagName(pitch.code), pitch.octave });
}
```

## Development

```sh
zig build test
```

## License

Licensed under either of [Apache License, Version 2.0](LICENSE-APACHE) or [MIT license](LICENSE-MIT) at your option.
