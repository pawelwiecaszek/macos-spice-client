Synthetic TLS/RSA fixtures generated locally with OpenSSL for tests only
(no keys from real infrastructure; private keys were discarded).

- `test-server.pem` — self-signed certificate,
  subject `O=Proxmox Virtual Environment, OU=PVE Cluster Node, CN=pve-test.example.invalid`.
- `ticket-key.spki.der` — RSA-1024 SubjectPublicKeyInfo (162 bytes, as in `SpiceLinkReply`).
- `ticket-key.pkcs1.der` — the same key as PKCS#1 `RSAPublicKey`.
