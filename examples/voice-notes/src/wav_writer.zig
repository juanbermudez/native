//! A deliberately tiny PCM WAV encoder for the voice-notes sample.
//!
//! Capture stays f32 on the realtime callback path. Only after capture has
//! stopped do we quantize into a regular little-endian PCM WAV buffer, ready
//! for the effects channel's whole-file write. This is a convenience of the
//! example, not an audio codec or a recording subsystem API.

const std = @import("std");
const native_sdk = @import("native_sdk");

pub const header_bytes: usize = 44;

pub const Error = error{
    InvalidFormat,
    BufferTooSmall,
};

/// Encode interleaved f32 PCM as a RIFF/WAVE PCM-16 file. A final incomplete
/// frame is excluded rather than inventing a channel sample.
pub fn encodePcm16(samples: []const f32, format: native_sdk.AudioInputFormat, out: []u8) Error![]const u8 {
    if (format.sample_rate_hz == 0 or format.channels == 0 or format.channels > 2) return error.InvalidFormat;

    const channels: usize = format.channels;
    const aligned_samples = samples.len - @mod(samples.len, channels);
    const data_bytes = std.math.mul(usize, aligned_samples, @sizeOf(i16)) catch return error.BufferTooSmall;
    const total_bytes = std.math.add(usize, header_bytes, data_bytes) catch return error.BufferTooSmall;
    if (out.len < total_bytes) return error.BufferTooSmall;

    @memcpy(out[0..4], "RIFF");
    std.mem.writeInt(u32, out[4..8], @intCast(total_bytes - 8), .little);
    @memcpy(out[8..12], "WAVE");
    @memcpy(out[12..16], "fmt ");
    std.mem.writeInt(u32, out[16..20], 16, .little);
    std.mem.writeInt(u16, out[20..22], 1, .little); // PCM
    std.mem.writeInt(u16, out[22..24], format.channels, .little);
    std.mem.writeInt(u32, out[24..28], format.sample_rate_hz, .little);
    const bytes_per_second: u32 = format.sample_rate_hz * @as(u32, format.channels) * @sizeOf(i16);
    std.mem.writeInt(u32, out[28..32], bytes_per_second, .little);
    std.mem.writeInt(u16, out[32..34], format.channels * @sizeOf(i16), .little);
    std.mem.writeInt(u16, out[34..36], 16, .little);
    @memcpy(out[36..40], "data");
    std.mem.writeInt(u32, out[40..44], @intCast(data_bytes), .little);

    for (samples[0..aligned_samples], 0..) |sample, index| {
        const pcm = quantize(sample);
        const offset = header_bytes + index * @sizeOf(i16);
        std.mem.writeInt(i16, out[offset..][0..@sizeOf(i16)], pcm, .little);
    }
    return out[0..total_bytes];
}

fn quantize(sample: f32) i16 {
    if (std.math.isNan(sample)) return 0;
    const clipped = @max(-1.0, @min(1.0, sample));
    // Use symmetric full-scale on both sides: -1.0 maps to -32767, avoiding
    // a special case and preserving the expected sign in every sample.
    return @intFromFloat(@round(clipped * 32767.0));
}

test "encodes a conventional mono PCM-16 WAV header and clipped samples" {
    const testing = std.testing;
    const samples = [_]f32{ -1.0, -0.5, 0.0, 0.5, 1.2 };
    var out: [header_bytes + samples.len * 2]u8 = undefined;
    const wav = try encodePcm16(&samples, .{ .sample_rate_hz = 48_000, .channels = 1 }, &out);

    try testing.expectEqual(@as(usize, header_bytes + samples.len * 2), wav.len);
    try testing.expectEqualStrings("RIFF", wav[0..4]);
    try testing.expectEqualStrings("WAVE", wav[8..12]);
    try testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, wav[20..22], .little));
    try testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, wav[22..24], .little));
    try testing.expectEqual(@as(u32, 48_000), std.mem.readInt(u32, wav[24..28], .little));
    try testing.expectEqual(@as(i16, -32767), std.mem.readInt(i16, wav[44..46], .little));
    try testing.expectEqual(@as(i16, 32767), std.mem.readInt(i16, wav[wav.len - 2 ..][0..2], .little));
}

test "rejects an incomplete format and never overflows its caller buffer" {
    const testing = std.testing;
    var too_small: [header_bytes]u8 = undefined;
    try testing.expectError(error.InvalidFormat, encodePcm16(&.{0.0}, .{}, &too_small));
    try testing.expectError(error.BufferTooSmall, encodePcm16(&.{ 0.0, 0.0 }, .{ .sample_rate_hz = 48_000, .channels = 1 }, &too_small));
}
