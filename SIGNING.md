# Update signing (maintainer notes)

The auto-updater (`pkeep update`) will only install a release whose `SHA256SUMS`
manifest carries a valid **RSA-3072 signature** from this project's key. The
checksums prove the files match the manifest; the signature proves the manifest
came from the maintainer. Together they mean a compromise of the GitHub repo,
the `raw.githubusercontent.com` CDN, or the TLS connection is **not enough** to
push code — an attacker would also need the offline private key.

Verification on the client uses macOS's built-in `openssl` (LibreSSL), so users
install nothing extra.

## Keys

- **Private key:** `~/.config/printer-keepalive/update.md` — RSA-3072,
  `chmod 600`, **never committed**. It uses a `.md` extension (it's plain PEM;
  openssl ignores the extension), so the repo `.gitignore` blocks `*.key`,
  `*.pem` **and the exact name `update.md`** as a backstop — note it can't be a
  blanket `*.md` ignore because the repo's docs are markdown too. ⚠️ Because the
  key is markdown-named, keep it OUT of any notes/markdown vault that syncs to
  the cloud. **Back it up** in your password manager. If it's lost you can no
  longer ship verifiable updates and must migrate users via a fresh clone with a
  new key.
- **Public key:** embedded as the `UPDATE_PUBKEY` constant in `src/pkeep`. The
  client verifies with **its own installed** copy of this key
  (trust-on-first-use), never a freshly downloaded one.

One-time generation (already done):

```sh
mkdir -p ~/.config/printer-keepalive && chmod 700 ~/.config/printer-keepalive
umask 077
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:3072 \
    -out ~/.config/printer-keepalive/update.md
chmod 600 ~/.config/printer-keepalive/update.md
openssl pkey -in ~/.config/printer-keepalive/update.md -pubout   # paste into UPDATE_PUBKEY
```

## Shipping a release

**Preferred:** use the release helper — it bumps both VERSIONs, syntax-checks,
regenerates **and signs** the manifest (refusing to proceed if the key is
missing/mismatched), syncs the live copy, and commits + pushes:

```sh
./release.sh --dry-run 1.0.1       # validate everything (incl. real signing) first
./release.sh 1.0.1 -m "fix: …"     # cut it: bump → sign → commit → push
./release.sh 1.0.1                 # or stop before commit so you can review
```

### Manual fallback (what release.sh does under the hood)

After you've finalised `src/`, bumped both VERSIONs, and synced the live copy,
regenerate **and sign** the manifest, then commit the `.sig` alongside it:

```sh
cd <repo>
( cd src && shasum -a 256 printer-keepalive.sh pkeep > ../SHA256SUMS )
openssl dgst -sha256 -sign ~/.config/printer-keepalive/update.md \
    -out SHA256SUMS.sig SHA256SUMS
# sanity check before committing:
openssl pkey -in ~/.config/printer-keepalive/update.md -pubout 2>/dev/null > /tmp/pk.pub
openssl dgst -sha256 -verify /tmp/pk.pub -signature SHA256SUMS.sig SHA256SUMS   # → Verified OK
git add SHA256SUMS SHA256SUMS.sig src/ VERSION
git commit && git push
```

**Rule:** once a signed release is published, **never publish an unsigned
manifest again** — the client treats a missing/invalid signature as a hard
failure.

## Rotating the key

If you must rotate (suspected compromise, or routine hygiene):

1. Generate `update.md.new` and its public key.
2. In `src/pkeep`, set `UPDATE_PUBKEY` to the **new** public key.
3. Sign that release's `SHA256SUMS` with the **OLD** key — installed clients
   still carry the old public key, so that's what they verify against. (If you
   sign with the new key, no existing client can verify it.)
4. Ship. Once the fleet has moved onto the release carrying the new public key,
   subsequent releases are signed with the new key.
