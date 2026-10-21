# Display stream captures

Real SPICE display-channel streams recorded from QEMU 8.2 / spice-server 0.15.1 (QXL),
booting `anim.asm` (a 320×200 VGA animation: a static checkerboard band plus moving
gradients, 40 frames). Each file is the raw sequence of server→client messages in
mini-header form (`u16 type, u32 size, payload`), recorded with the client's preferred
image compression set to:

| File | Compression | Image types seen |
|---|---|---|
| `lz.bin` | LZ (6) | LZ_RGB |
| `lz4.bin` | LZ4 (7) | LZ4 |
| `glz.bin` | GLZ (5) | GLZ_RGB |
| `auto-glz.bin` | AUTO_GLZ (2) | GLZ_RGB |

The content is identical in all four, so the final primary surface must match pixel for
pixel; the LZ decoder (verified against reference fixtures) is the baseline.
No hostnames, tickets or keys are contained.
