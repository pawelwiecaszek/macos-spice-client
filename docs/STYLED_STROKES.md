# Styled strokes: straight geometric figures

C1 stroke slice C, 2026-11-18. Adds width-one geometric dashed horizontal/vertical
figures, including orthogonal joins and closure. Joined diagonal figures are also supported. Curved styled paths
remain unsupported as a whole; no earlier segment is painted before that rejection.
This is not full styled-stroke or C1 completion. The installed Phase 5 app and PR remain
unchanged by this local implementation.

## Pinned behavior and fixtures

The pinned [software renderer](https://gitlab.freedesktop.org/spice/spice-common/-/blob/58d375e5eadc6fb9e587e99fd81adcb95d01e8d6/common/canvas_base.c#L2924)
uses LineOnOffDash and changes zero-width dashed lines to width-one geometric strokes.
It does not apply backMode to gaps: they remain untouched. This is software-reference
compatibility, not a claim that every backend handles that metadata identically.

An isolated temporary harness compiled the unchanged pinned
[lines.c](https://gitlab.freedesktop.org/spice/spice-common/-/blob/58d375e5eadc6fb9e587e99fd81adcb95d01e8d6/common/lines.c)
with pixel-recording callbacks. UBSan passed the small fixtures below. No reference
implementation or dependency was added to the project.

For `(0,0) -> (8,0)`, foreground x coordinates are:

| Style in rounded pixels | Normal | START_WITH_GAP |
| --- | --- | --- |
| 2,2 | 0,1,4,5 | — |
| 3,1 | 0,1,2,4,5,6 | 3,7 |
| 2,3,1 | 0,1,5,6,7 | 1,2,3,4,5,7 |

Reverse `(8,0) -> (0,0)` with style 2,2 paints x=2,3,6,7. Reusing the zero-width
cosmetic line endpoints would shift these pixels. Vertical fixtures are analogous.

Phase continues over complete axis-segment lengths, including clipped distance, and
resets at each figure boundary. START_WITH_GAP rotates the list left and applies the
new first length as offset. Odd lists wrap to index zero without doubling the period.
The endpoint foreground rule is distinct from the last pixel's state: for style 2,3,1,
position 5 is foreground but the endpoint state at distance 6 is not. Tests lock the
resulting absent miter pixels in both normal and START_WITH_GAP corner fixtures.

Width-one miter joins add a turning pixel when both adjacent foreground pieces touch
and their segment rectangles omit that vertex. Closed-square and retrace fixtures
verify this geometry. Foreground coverage is applied once per figure, preserving XOR
and other destination-dependent modes; a new figure may modify the same pixel again.
Solid/pattern brushes and native x555/r565/xRGB/ARGB operations reuse the existing color
and foreground-raster helpers. Pattern images remain snapshots of the pre-draw surface.

## Safety and scope

- Rounded style lengths must be 1...255 pixels and lists contain 1...255 entries.
  Values that would normalize to zero or wrap the reference's byte storage are rejected
  rather than emulated. The period is at most 65,025 pixels.
- Prefix sums and bounded binary queries skip arbitrary offscreen phase distances
  without walking them. Diagonal metrics use geometric distance with integer-verified dash boundaries and
  ceiling phase advancement per segment. Curved styles remain guarded.
- Complete preflight limits a draw to 65,536 spans, 131,072 span/join operations and
  8 Mi visible-step/clip tests before modifying pixels. Existing wire/path limits remain.
- Coverage uses at most one bit per clipped bounding-area pixel plus one index per
  touched word. Figure changes clear only touched words; repeated tiny figures cannot
  force full-surface clearing. Reset work is bounded by actual painted coverage.
- Invalid styles, unsupported geometry and exhausted budgets leave pixels unchanged.
  The channel translates exhausted work budgets into its existing hard-limit failure.

## Validation boundary

Tests cover reference pixels in both directions, vertical equivalents, phase at corners,
odd/gap normalization, endpoint joins, closure, retrace union, reset across figures,
clipping and offscreen skipping, aliased patterns, native formats and unchanged pixels
on rejection. The wire fixture patches style offsets after complete path construction;
its decoded styles and cubic flag are checked so rejection tests exercise the intended
unsupported geometry. A throughput benchmark reports timings without a speed threshold.

Live styled-stroke captures remain pending. Remaining C1 work includes
curved geometric dash rendering, then text. A normal desktop launch does not by itself
establish that the guest emitted a styled stroke.

## Standalone diagonal extension

A further local slice adds individual diagonal segments in every octant. Width-one
geometric coverage uses integer pixel centers and top-left half-open boundaries,
not cosmetic Bresenham pixels. Dash cuts use Euclidean distance. Exact Int128
squared comparisons determine both band and dash membership; floating estimates
only propose candidate bounds and a distance cell, then integer comparisons correct
that cell. The final cap uses the original squared segment length, avoiding a
rounded square-root product that can incorrectly include the endpoint.

Thirty-two fixed oracle fixtures cover positive/negative slopes, shallow/steep
segments and reversed endpoints. An external mathematical experiment matched 648
small reference cases. Clipping, native 16-bit colors, extreme offscreen coordinates,
and atomic work-limit rejection have regression tests. Rows examine only a
conservative narrow band; invisible dash lengths are never walked.

Separate figures may mix axis and diagonal paths. Existing axis-only figures retain
their renderer. Mixed figures preserve exact integer cap/band coverage and advance
phase by the ceiling of each segment's Euclidean length. The ceiling is corrected
with integer squared comparisons. Curved styles remain guarded.

## Joined diagonal extension

Straight diagonal figures now support miter joins, closure, and retracing. A join
is admitted only when both neighboring foreground pieces touch according to the
reference's post-rounding endpoint rule. Outer wedges use exact integer cap/band
tests. Miters exceeding the reference limit become bevels, whose boundary retains
the reference's normalized 16-bit slope quantization. Every wedge stays within six
pixels of its vertex and participates in the same preflight work budget.

The width-one software renderer treats destination-idempotent operations differently:
some joins are omitted when adjacent segment rectangles already cover the vertex.
This can affect acute corners beyond the vertex, so COPY and XOR intentionally have
separate reference expectations. The renderer classifies the actual foreground
Boolean operation by its two-input truth table, including inversion flags.

Regression fixtures cover 256 turns in all octants under COPY/XOR, plus 54 acute
miter/bevel, reversed, closed, retraced, odd START_WITH_GAP and phase cases, and the
24 earlier corner fixtures. The fixed outputs were produced by the unchanged pinned
reference outside this repository; no reference implementation is included. A larger
external sweep matched 2,048 cases. Additional tests check that exhausting join work
rejects the complete draw before changing an earlier figure, and that wire-decoded
joined paths preserve phase. Live capture acceptance remains pending.
