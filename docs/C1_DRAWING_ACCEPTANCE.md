# C1 drawing acceptance — local automated baseline

Reviewed at 222a764. The scoped automated baseline passes; live command-specific
acceptance remains pending. This permits C3 work under the roadmap's separate-gates
rule without claiming full protocol parity, publishing, or updating the installed app.

| Area | Local acceptance evidence | Remaining boundary |
| --- | --- | --- |
| ROP3 | All Boolean truth tables; packed wire decoding; clip/mask/scaling/native formats; display delivery | Sanitized production ROP3 capture |
| Solid/styled strokes | Straight/cubic/closed figures; dash phase and joins; fixed reference pixels; clipping, native formats, work limits; display delivery | Production stroke captures; documented robustness differences for pathological curves |
| Raster text | A1/A4/A8; both row orders; solid/pattern brushes; native 555/565 and 32-bit compositing; wire delivery and malformed/work limits | Production text captures; non-PUT foreground modes remain unsupported |
| Existing images | Existing real-server LZ/LZ4/GLZ replays remain passing | Image replays do not demonstrate the other command types |
| Composite | Handler remains unsupported and capability is not advertised | Separate contract and use case before implementation |

Fresh acceptance evidence: 282 core tests passed in
`/private/tmp/spice-text-formats-core.log`; Release passed with Swift warnings treated
as errors in `/private/tmp/spice-text-formats-release.log`; strict code-signature
verification passed. Independent verifier found no implementation blocker. These local
logs are session artifacts, not fixtures shipped with the application.

Implementation details and deliberate compatibility policies are recorded in
[ROP3](ROP3_DRAWING.md), [strokes](STROKE_DRAWING.md), [styled strokes](STYLED_STROKES.md)
and [text](TEXT_DRAWING.md). Missing captures block live claims, not unrelated offline
work. No audio/video timing acceptance is implied by drawing acceptance.
