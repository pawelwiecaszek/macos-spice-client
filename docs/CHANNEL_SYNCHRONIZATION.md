# Channel ordering and cache ownership

C2 implementation, 2026-11-11. Automated verification is separate from live acceptance.

Every authenticated channel registers with one session-local ordering actor. Mini-header
serials start at one and count every outer message, including base messages. A delivered
message becomes complete only after its handler finishes. Base messages complete inside
the receive loop; channel handlers acknowledge at the next iteration. Fatal exits close
the channel rather than publishing unfinished work.

Both `WAIT_FOR_CHANNELS` and display `INVAL_ALL_PIXMAPS` decode an inline byte count
followed by packed `(type: UInt8, id: UInt8, serial: UInt64 little-endian)` entries.
Invalidation waits before clearing the pixmap cache. Strict lengths reject truncation
and trailing data. Unknown channels after manifest publication, failed/closed peers,
impossible self-dependencies and timeout fail explicitly. Limits are 64 tracked channels,
64 pending waits, 255 dependencies per wait and a 30-second wait timeout. Cancellation
and session shutdown release continuations; channel tokens reject stale completions.

Each display's pixmap cache and GLZ dictionary advertise its channel ID, including zero.
This matches the existing independent client resolvers: the server keys these resources
by client and requested ID. Cross-display image references are intentionally unavailable.
A display identity cannot reopen within the same main session because closing a socket
does not prove server dictionary destruction. Reconnect creates a fresh session.

This slice does not add submessage-list dispatch, migration, additional drawing commands,
multi-head presentation or automatic reconnect.

## Pinned contracts

- [spice-gtk serial progression](https://gitlab.freedesktop.org/spice/spice-gtk/-/blob/f04479c16f0969fb394ebe74b6eff74e560a42f0/src/spice-channel.c): implicit mini-header serial and completion after dispatch.
- [spice-common schema](https://gitlab.freedesktop.org/spice/spice-common/-/blob/58d375e5eadc6fb9e587e99fd81adcb95d01e8d6/common/spice.proto): packed waits and display initialization fields.
- [spice-server cache ownership](https://gitlab.freedesktop.org/spice/spice/-/blob/0c2c1413a8b387ea597a95b6c867470a7c56c8ab/server/pixmap-cache.cpp) and [encoder dictionaries](https://gitlab.freedesktop.org/spice/spice/-/blob/0c2c1413a8b387ea597a95b6c867470a7c56c8ab/server/image-encoders.cpp): resource namespaces use the requested ID per client.

## Evidence and remaining acceptance

Regression tests cover wire lengths/endian layout, processed versus merely received
serials, delayed registration, missing/closed peers, cancellation/timeout, bounded waits,
stale tokens and session replacement. Display tests inspect actual initialization IDs,
block invalidation behind an unfinished peer, isolate pixmap references, and replay real
GLZ histories to verify dictionary ownership. The original code failed strict-length
and distinct-ID regressions before implementation.

Live acceptance remains pending: connect a desktop, exercise input and resizing, close
and reopen it, and check for rendering regressions. Multiple display channels should be
tested when available; single-display success does not establish multi-display coverage.
No installed application replacement or publication is included in this slice.
