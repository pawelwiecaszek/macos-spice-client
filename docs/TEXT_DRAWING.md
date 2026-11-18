# Text drawing: A1/A4 coverage and brush patterns

This local C1 slice adds packed DRAW_TEXT decoding and bottom-up A1/A4 rendering.
A4 coverage and pattern brushes support xRGB/ARGB surfaces. Native x555/r565 retain
A1 solid-brush support. A8, TOP_DOWN, antialiased native-16 text and native-16 text
patterns remain unsupported before any background or foreground pixels change.
Rendering accepts foreground mode PUT. No installed-app or PR update is included.

## Wire and rendering contract

Pinned evidence: [spice-common schema](https://gitlab.freedesktop.org/spice/spice-common/-/blob/58d375e5eadc6fb9e587e99fd81adcb95d01e8d6/spice.proto),
[mask construction](https://gitlab.freedesktop.org/spice/spice-common/-/blob/58d375e5eadc6fb9e587e99fd81adcb95d01e8d6/common/canvas_base.c#L1566),
and [software text rendering](https://gitlab.freedesktop.org/spice/spice-common/-/blob/58d375e5eadc6fb9e587e99fd81adcb95d01e8d6/common/sw_canvas.c#L1049).
The packed string contains u16 count, u8 flags and inline variable-length glyphs.
The schema's ptr_array annotation describes C memory layout, not wire offsets.
Each glyph has two signed points, u16 dimensions, and byte-aligned packed rows.
A1 rows are bottom-up and bits are MSB first. The glyph box starts at render position
plus glyph origin; checked arithmetic rejects overflowing geometry.

Glyph coverage is united with maximum alpha before painting. A4 rows store the high
nibble first and expand each nibble by shifting left four bits: maximum coverage is
240 rather than 255. Solid foreground colors become opaque, so A1 foreground OVER
reduces to replacement on covered pixels. Background uses
COPY within its separate rectangle, command box, clip union and surface. The software
reference ignores back_mode; this slice preserves that behavior rather than applying
stroke ROP semantics to text. Solid brushes use native surface words: x555/r565 are expanded for the existing A1
path, and xRGB/ARGB solid colors become opaque. Pattern buffers retain premultiplied
alpha when present; opaque images force alpha to 255.

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

## Antialiasing and pattern verification

The existing premultiplied compositor is reused. Mask coverage scales source alpha
and every source channel separately with rounded divide-by-255, then OVER adds the
rounded destination contribution. Combining those roundings would change edge pixels.
The installed Pixman 0.46.4 library supplied an isolated UBSan-clean oracle, without
adding any application dependency. Tests lock 160 32-bit A4-compatible oracle cases,
eight pattern/alignment pixels, maximum overlap, clipping, background ordering,
pattern snapshot aliasing, and A4 wire delivery. Source-derived A1 tests remain gates.

Foreground pattern coordinates start at the complete glyph union's origin, then
subtract the pattern origin; clipping does not move the anchor. Background patterns
use destination coordinates and COPY, including source alpha on ARGB surfaces. Pattern
buffers are snapshots so a surface used as its own brush does not feed back new pixels.

## Remaining work

The pinned solid-brush conversion uses questionable five-bit depth-16 handling marked
incorrect upstream. Destination 555/565 blending matches the Pixman oracle, but solid
source conversion needs an explicit native policy before enabling A4 there. Existing
A1 native-format behavior is preserved. Native text patterns also remain guarded.
The pinned A8 mask path is marked untested and appears to read beyond the first row;
TOP_DOWN is explicitly unimplemented there. Follow protocol and safe evidence rather
than undefined behavior. Live text-specific captures remain pending. This slice does
not complete C1.
