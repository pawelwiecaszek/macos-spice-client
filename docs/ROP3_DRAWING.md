# ROP3 drawing contract and evidence

C1 first slice, 2026-11-17. Implements DRAW_ROP3; stroke, text and composite remain
separate work. The installed and published Phase 5 checkpoint remains unchanged.

## Contract

The packed message is DisplayBase, UInt32 image offset, source rectangle, brush,
UInt8 truth table, UInt8 scale mode, and QMask. Pattern/source/destination bits form
index `(P << 2) | (S << 1) | D`; the indexed truth-table bit is the output bit.
Examples: CC=source, F0=pattern, AA=destination, 66=source XOR destination.

The implementation evaluates all bit positions together. xRGB output is opaque;
ARGB includes its high byte in the Boolean operation rather than alpha blending.
x555/r565 source, pattern and destination operands are quantized to packed target
format before evaluation; solid brush colors are already packed in that format.
Alpha-only and unknown surface formats are rejected for this operation.

Source scaling stays anchored to the original source rectangle and drawing box.
Nearest sampling is exact; interpolation uses a source-area-clamped bilinear filter.
The protocol permits interpolation without mandating Pixman's exact coefficients,
so pixel identity with every server/reference interpolation path is not claimed.
Native 16-bit interpolation quantizes contributing samples before filtering.

Pattern alignment uses destination coordinates and positive-modulo tiling. Mask
coordinates are relative to the original box plus mask position; inverted masks still
exclude pixels outside the bitmap. Unsupported nonnull masks reject the draw instead
of becoming unmasked. Invalid source offsets, scale modes and mask flags are rejected.

Overlapping clip rectangles paint each pixel once. Multiple rectangles use a temporary
visited bitset over their clipped bounding area, at most one extra bit per surface
pixel. A pre-mutation work budget limits clip traversal to eight bounding-area passes, capped
at 64 Mi pixel visits while allowing one full-area pass for larger surfaces. Excessive
overlap closes the display channel before painting. Existing surface/image/message
allocation limits remain in force. No allocation
occurs per pixel. Source and pattern surfaces are resolved before destination mutation,
preserving copy-on-write snapshots when images refer to that destination.

## Pinned references

- [Current schema, DRAW_ROP3](https://gitlab.freedesktop.org/spice/spice-common/-/blob/58d375e5eadc6fb9e587e99fd81adcb95d01e8d6/spice.proto#L847).
- [Current pointer generator](https://gitlab.freedesktop.org/spice/spice-common/-/blob/58d375e5eadc6fb9e587e99fd81adcb95d01e8d6/python_modules/ptypes.py#L583): offsets are four bytes; the historical HTML has stale pointer/enum widths.
- [SPICE rendering specification](https://www.spice-space.org/spice-protocol.html).
- [Ternary raster-operation indexing](https://learn.microsoft.com/en-us/windows/win32/gdi/ternary-raster-operations).
- [Pinned behavioral reference](https://gitlab.freedesktop.org/spice/spice-common/-/blob/58d375e5eadc6fb9e587e99fd81adcb95d01e8d6/common/canvas_base.c) and [native-word ROP behavior](https://gitlab.freedesktop.org/spice/spice-common/-/blob/58d375e5eadc6fb9e587e99fd81adcb95d01e8d6/common/rop3.c). Read for semantics; no LGPL implementation copied.

## Evidence boundary

New synthetic display tests failed against the previously skipped command before
integration. Tests now cover all 256 truth tables, independent per-bit pixel oracles,
packed wire layout/truncation/offsets, 16/32-bit golden pixels, scaling, pattern origins,
mask bounds/inversion, overlapping clips and source/pattern aliases. Existing real-server
LZ/LZ4/GLZ display replays remain part of the core gate. A throughput benchmark records
timing without a flaky speed threshold; it is not a measured live-VM performance claim.

Representative live ROP3 capture and desktop regression acceptance remain pending.
Passing an ordinary desktop launch alone does not establish that its server emitted
ROP3 or validate stroke/text/composite support.
