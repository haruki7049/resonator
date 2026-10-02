//! Multi-string or multi-channel instrument mapping to track (voice lane) indices.
//!
//! Each string of an instrument is a monophonic voice lane. An `Instrument` resolves a string index
//! to the index of the track that holds that lane, so a sequencer can keep strings on separate
//! tracks and let them ring together (chords) while each string stays monophonic.

const std = @import("std");

const Self = @This();

/// Instrument name (e.g. `"AcousticGuitar"`).
name: []const u8,
/// Track index for each string, 0-indexed from the lowest string.
string_indices: []usize,

/// Initializes an Instrument instance with track indices for each string/voice.
/// The instrument takes ownership of `string_indices`; free it with `deinit`.
pub fn init(name: []const u8, string_indices: []usize) Self {
    return .{
        .name = name,
        .string_indices = string_indices,
    };
}

/// Frees instrument string index allocations.
pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
    allocator.free(self.string_indices);
}

/// Returns the number of strings/voices associated with this instrument.
pub fn stringCount(self: Self) usize {
    return self.string_indices.len;
}

/// Resolves the underlying track index for a given string index.
pub fn getTrackIndex(self: Self, string_index: usize) !usize {
    if (string_index >= self.string_indices.len) return error.InvalidStringIndex;
    return self.string_indices[string_index];
}

test "Instrument stringCount and getTrackIndex" {
    const allocator = std.testing.allocator;
    const indices = try allocator.alloc(usize, 3);
    indices[0] = 10;
    indices[1] = 20;
    indices[2] = 30;

    var inst = Self.init("Acoustic Guitar", indices);
    defer inst.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 3), inst.stringCount());
    try std.testing.expectEqual(@as(usize, 10), try inst.getTrackIndex(0));
    try std.testing.expectEqual(@as(usize, 20), try inst.getTrackIndex(1));
    try std.testing.expectEqual(@as(usize, 30), try inst.getTrackIndex(2));
}

test "Instrument getTrackIndex out of range returns error.InvalidStringIndex" {
    const allocator = std.testing.allocator;
    const indices = try allocator.alloc(usize, 1);
    indices[0] = 5;

    var inst = Self.init("Single String", indices);
    defer inst.deinit(allocator);

    try std.testing.expectError(error.InvalidStringIndex, inst.getTrackIndex(1));
    try std.testing.expectError(error.InvalidStringIndex, inst.getTrackIndex(99));
}

test {
    std.testing.refAllDecls(@This());
}
