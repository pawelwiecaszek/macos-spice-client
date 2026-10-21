# Test fixtures

Everything here is synthetic. Never add real `.vv` files, tickets, host names or CA
material from production infrastructure.

| Folder | Contents |
|---|---|
| `vv/` | Hand-written virt-viewer files (Proxmox, oVirt, CRLF/BOM, plain QEMU, VNC). Hosts use `.invalid`/`192.0.2.x`; tickets are placeholders. |
| `codecs/` | QUIC and LZ streams + `manifest.json`. |
| `tls/` | Self-signed certificate and RSA-1024 public key (see `tls/README.md`). |

## `codecs/`

Produced by encoding synthetic images (gradient, noise, "desktop" with runs, stripes,
wide rows > 2048 px to exercise QUIC wait-mask segments, 1×1 and 1×N edge cases) with the
reference spice-common 0.16 encoders in a throw-away harness that is **not** part of this
repository (LGPL). Only the encoder output is committed.

`manifest.json` lists, per stream: codec, size, optional palette, and `fnv` — FNV-1a-64
over the expected decoded pixels (`0xAARRGGBB` per pixel, little-endian bytes, top-down).
Expected pixels are the original image: x555 channels are expanded with `(v << 3) | (v >> 2)`,
RGB without alpha has alpha `0xFF`, A8/XXXA keep RGB at 0.
