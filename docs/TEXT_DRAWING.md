# Text drawing: raster glyphs and brush patterns

This local C1 implementation decodes and renders A1/A4/A8 raster glyphs in both
bottom-up and TOP_DOWN row orders. Solid and pattern brushes support xRGB/ARGB and
native x555/r565 surfaces. Rendering accepts foreground mode PUT; other foreground
modes remain recoverable unsupported errors before pixels change. No installed-app
or PR update is included.

## Wire and rendering contract

Pinned evidence: [spice-common schema](https://gitlab.freedesktop.org/spice/spice-common/-/blob/58d375e5eadc6fb9e587e99fd81adcb95d01e8d6/spice.proto),
[mask construction](https://gitlab.freedesktop.org/spice/spice-common/-/blob/58d375e5eadc6fb9e587e99fd81adcb95d01e8d6/common/canvas_base.c#L1566),
and [software text rendering](https://gitlab.freedesktop.org/spice/spice-common/-/blob/58d375e5eadc6fb9e587e99fd81adcb95d01e8d6/common/sw_canvas.c#L1049).
The packed string contains u16 count, u8 flags and inline variable-length glyphs.
The schema's ptr_array annotation describes C memory layout, not wire offsets.
Each glyph has two signed points, u16 dimensions, and byte-aligned packed rows.
A1 bits are MSB first. A8 has one coverage byte per pixel, with stride equal to width.
Rows are bottom-up unless TOP_DOWN makes row zero the top glyph row. The glyph box starts at render position
plus glyph origin; checked arithmetic rejects overflowing geometry.

Glyph coverage is united with maximum alpha before painting. A4 rows store the high
nibble first and expand each nibble by shifting left four bits: maximum coverage is
240 rather than 255. Solid foreground colors become opaque, so A1 foreground OVER
reduces to replacement on covered pixels. Background uses
COPY within its separate rectangle, command box, clip union and surface. The software
reference ignores back_mode; this slice preserves that behavior rather than applying
stroke ROP semantics to text. Solid brushes use native surface words: x555/r565 words are expanded according to their distinct native layouts, and
xRGB/ARGB solid colors become opaque. Pattern buffers retain premultiplied
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

## A8, TOP_DOWN and native-format policy

The [official glyph protocol](https://www.spice-space.org/spice-protocol.html) defines
A8 as eight-bit alpha and TOP_DOWN as line zero at the top. The current pinned schema
supplies the actual packed field widths. Native row selection follows that definition
for every format. The pinned software renderer's A8 one-past-row read and TOP_DOWN
TODO are corrected rather than reproduced; safe bounded accesses are tested at the
first/last rows, and truncated A8 data rejects before background painting.

Native solid colors use the client's existing distinct 555/565 word layouts and
bit-replication expansion. This is an explicit native-color policy rather than bug
compatibility with the pinned reference's five-bit-all-channels conversion, which is
marked incorrect upstream. For native destinations, background COPY is packed and
expanded before foreground OVER; final output is packed and expanded again. Native
background alpha is discarded. Pattern sources retain their own premultiplied alpha
for OVER. Quantizing only at the end would produce different pixels.

Two additional Pixman oracle tables lock 160 native-destination OVER cases and 240
sequential background-COPY/foreground-OVER cases. Tests cover native solid layout,
all glyph row orders, exact A8 coverage, maximum overlap, truncated rows, and A8
TOP_DOWN wire delivery. Earlier A1/A4, clipping, aliasing and resource-limit tests remain
regression gates.

## Acceptance boundary

ROP3, solid/styled strokes and baseline raster text now have local automated coverage.
Non-PUT text foreground modes remain explicitly unsupported. Live text-specific
captures and deployment acceptance remain pending; ordinary desktop launch does not
prove which drawing commands the guest emitted. Full SPICE parity is not claimed.
