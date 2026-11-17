# Stroke drawing: solid cosmetic paths

C1 stroke slice A, 2026-11-17. Implements solid one-pixel polylines and closed
figures. Cubic paths and styled strokes are decoded, validated and rejected as a
whole until their next rasterization slices have reference fixtures. They never
leave a partially painted figure. Text remains a separate C1 slice.

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
line-walking loops. Invalid or unsupported operations preserve the target surface.

## Evidence and remaining work

Tests cover packed offsets/flags, truncation, malformed paths, fixed-coordinate extremes,
endpoint/closed-figure golden pixels, all-octant direct versus incremental sampling,
clip unions, offscreen skipping, patterned/aliased brushes, native formats and raster
operations. Work-limit and unsupported-path tests require unchanged pixels. End-to-end
synthetic display tests failed against the skipped command before integration and now
exercise wire-to-surface behavior. Existing ROP3 and real-server image replays protect
the shared-helper move.

Independent review passed after adding an inversion-only descriptor fallback regression.
Live stroke-specific captures remain pending. Follow-up slices
must establish cubic flattening and styled/dash reference pixels, including gap and
background semantics, before enabling those paths. Ordinary desktop launch alone does
not prove that a server emitted any stroke command. The installed Phase 5 app and its
PR remain unchanged by this local slice.
