const std = @import("std");
const testing = std.testing;

const c = @cImport({
    @cInclude("spectrum_bins.h");
});

test "spectrum bin range rejects a bucket wholly above Nyquist" {
    var low: c_int = -1;
    var high: c_int = -1;

    try testing.expectEqual(
        @as(c_int, 0),
        c.NativeSdkSpectrumClampBinRange(1192, 1400, 1023, &low, &high),
    );
    try testing.expectEqual(@as(c_int, -1), low);
    try testing.expectEqual(@as(c_int, -1), high);
}

test "spectrum bin range clamps valid buckets inside the power array" {
    var low: c_int = 0;
    var high: c_int = 0;

    try testing.expectEqual(
        @as(c_int, 1),
        c.NativeSdkSpectrumClampBinRange(900, 1400, 1023, &low, &high),
    );
    try testing.expectEqual(@as(c_int, 900), low);
    try testing.expectEqual(@as(c_int, 1023), high);

    try testing.expectEqual(
        @as(c_int, 1),
        c.NativeSdkSpectrumClampBinRange(0, 0, 1023, &low, &high),
    );
    try testing.expectEqual(@as(c_int, 1), low);
    try testing.expectEqual(@as(c_int, 1), high);
}
