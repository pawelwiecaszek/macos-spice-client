# Stroke drawing: solid cosmetic paths

C1 stroke slices A–B, 2026-11-17. Implements solid one-pixel polylines, cubic curves
and closed figures. [Styled figures](STYLED_STROKES.md) also have reference fixtures
and bounded rendering, including diagonal joins and complete cubic subdivision.
Unsupported metadata and exhausted budgets reject the complete draw before painting.
Text remains a separate C1 slice.

## Verified contract

Pinned spice-common `58d375e5eadc6fb9e587e99fd81adcb95d01e8d6`:

- [Packed schema](https://gitlab.freedesktop.org/spice/spice-common/-/blob/58d375e5eadc6fb9e587e99fd81adcb95d01e8d6/spice.proto): `Path` is a segment count followed by inline variable-length segments; the C pointer-array annotation is not a wire pointer table. The message carries UInt32 path/style offsets, byte flags and optional byte style count, a brush and UInt16 foreground/background ROP descriptors.
- Path flags are BEGIN=1, END=2, CLOSE=8, BEZIER=16. Line flags are STYLED=8 and START_WITH_GAP=4. Coordinates and styles use signed 28.4 fixed-point values. There is no width/cap/join field in this wire layout.
- [Cosmetic-line behavior](https://gitlab.freedesktop.org/spice/spice-common/-/blob/58d375e5eadc6fb9e587e99fd81adcb95d01e8d6/common/canvas_base.c): fixed-coordinate rounding uses nearest integer with exact halves rounded down; lines exclude the final endpoint. Closed figures close back to the initial point without painting that shared endpoint twice.
- [Line rasterization reference](https://gitlab.freedesktop.org/spice/spice-common/-/blob/58d375e5eadc6fb9e587e99fd81adcb95d01e8d6/common/lines.c): directional cosmetic-line ties. The native implementation uses an original direct integer sampling formula and can skip distant offscreen pixels without losing phase. No reference implementation was copied into the repository.

Solid brushes use packed target-format colors. Pattern images are aligned in destination
coordinates and snapshotted before mutation. Foreground ROPs use the brush inversion
flag, not source inversion; native x555/r565 and xRGB/ARGB word operations share the
format conversion helpers with ROP3. Alpha-only surface formats remain unsupported.
Overlapping clip rectangles form a union; normal self-intersections of path segments
retain sequential raster operations.

## Hostile-input bounds

The parser allows at most 4,096 segments and 65,536 points per message, checks offsets,
lengths, known flags, path state and cubic control groups before rendering. Styled
arrays have the wire byte-count bound and positive lengths. A stroke preflight limits
visible-step/clip tests to 8 Mi visits before modifying any pixel. Rendering visits
only the visible major-axis range, so huge offscreen coordinates do not produce huge
line-walking loops. Cubic planning also caps a draw at 65,536 subdivision visits,
65,536 generated endpoints and depth 32; the visible line plan is capped at 65,536
entries. All budgets apply before painting. Invalid or unsupported operations preserve
the target surface.

## Evidence and remaining work

Tests cover packed offsets/flags, truncation, malformed paths, fixed-coordinate extremes,
endpoint/closed-figure golden pixels, all-octant direct versus incremental sampling,
clip unions, offscreen skipping, patterned/aliased brushes, native formats and raster
operations. Work-limit and unsupported-path tests require unchanged pixels. End-to-end
synthetic display tests failed against the skipped command before integration and now
exercise wire-to-surface behavior. Existing ROP3 and real-server image replays protect
the shared-helper move. [Cubic contract and oracle fixtures](CUBIC_STROKES.md) cover
rounded continuation, quantized subdivision, clipping and degenerate curves.

Independent review passed after adding an inversion-only descriptor fallback regression.
Live stroke-specific captures remain pending. Follow-up slices
must establish text drawing contracts before enabling that command.
Straight axis/diagonal dash, join and overlap behavior is covered by the styled-stroke fixtures. Ordinary desktop launch alone does
not prove that a server emitted any stroke command. The installed Phase 5 app and its
PR remain unchanged by this local slice.
