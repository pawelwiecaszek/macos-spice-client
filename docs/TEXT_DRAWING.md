# Text drawing: monochrome solid brushes

This local C1 slice adds packed DRAW_TEXT decoding and bottom-up A1 rendering.
It is partial text support: A4/A8 antialiasing, TOP_DOWN and pattern brushes remain
unsupported before any background or foreground pixels are modified. Rendering
accepts foreground mode PUT. No installed-app or PR update is included.

## Wire and rendering contract

Pinned evidence: [spice-common schema](https://gitlab.freedesktop.org/spice/spice-common/-/blob/58d375e5eadc6fb9e587e99fd81adcb95d01e8d6/spice.proto),
[mask construction](https://gitlab.freedesktop.org/spice/spice-common/-/blob/58d375e5eadc6fb9e587e99fd81adcb95d01e8d6/common/canvas_base.c#L1566),
and [software text rendering](https://gitlab.freedesktop.org/spice/spice-common/-/blob/58d375e5eadc6fb9e587e99fd81adcb95d01e8d6/common/sw_canvas.c#L1049).
The packed string contains u16 count, u8 flags and inline variable-length glyphs.
The schema's ptr_array annotation describes C memory layout, not wire offsets.
Each glyph has two signed points, u16 dimensions, and byte-aligned packed rows.
A1 rows are bottom-up and bits are MSB first. The glyph box starts at render position
plus glyph origin; checked arithmetic rejects overflowing geometry.

Glyph coverage is united before painting. Solid foreground colors become opaque,
so A1 foreground OVER reduces to replacement on covered pixels. Background uses
COPY within its separate rectangle, command box, clip union and surface. The software
reference ignores back_mode; this slice preserves that behavior rather than applying
stroke ROP semantics to text. All supported surface formats use native solid brush
words: x555/r565 are expanded, xRGB/ARGB colors become opaque.

For a 3x2 glyph at (1,1), source bytes 40 A0 produce top row 101 and bottom row 010.
Padding bits do not paint outside the declared width. Tests cover those exact pixels,
overlap, duplicate clips, background ordering, native colors and wire-to-surface delivery.
These are source-derived contract checks, not captured production text acceptance.

## Bounds and validation

The decoder and public-model validation limit strings to 4,096 glyphs, each dimension
to 16,384, aggregate decoded glyph area to 8 Mi pixels and source data to 8 MiB.
Data length must exactly match the declared dimensions/format. It recognizes A1/A4/A8
and TOP_DOWN metadata; unknown or multiple format bits reject. String offsets must
follow the command header. A truncated record or overflowing coordinate sum rejects.

Rendering allocates at most 8 MiB of clipped coverage. A shared 8 Mi work budget
covers visible glyph reads and paint/clip tests. All checks and mask construction
precede pixel mutation, including background painting. Work exhaustion becomes the
display channel's hard limit error; unsupported formats remain recoverable errors.

## Remaining work

Verify antialiased A4 compositing and native-format rounding before enabling it.
The pinned A8 mask path is marked untested and appears to read beyond the first row;
TOP_DOWN is explicitly unimplemented there. Follow the protocol and safe evidence,
not undefined behavior. Foreground pattern alignment is mask-relative in the software
reference and needs its own fixtures; alpha-bearing pattern sources require OVER.
Live text-specific captures remain pending. This slice does not complete C1.
