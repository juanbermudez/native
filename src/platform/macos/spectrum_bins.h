#ifndef NATIVE_SDK_SPECTRUM_BINS_H
#define NATIVE_SDK_SPECTRUM_BINS_H

/*
 * Clamp one requested FFT bucket to the non-DC half-spectrum.
 * A bucket wholly above Nyquist has no representative bin and must stay
 * empty; clamping it down to the last bin would fabricate high-frequency
 * energy and, before this helper existed, could restore an out-of-bounds
 * low index after the high index had already been clamped.
 */
static inline int NativeSdkSpectrumClampBinRange(
    int requested_low,
    int requested_high,
    int max_bin,
    int *low_out,
    int *high_out
) {
    if (max_bin < 1 || requested_low > max_bin) return 0;

    int low = requested_low < 1 ? 1 : requested_low;
    int high = requested_high > max_bin ? max_bin : requested_high;
    if (high < low) high = low;

    *low_out = low;
    *high_out = high;
    return 1;
}

#endif
