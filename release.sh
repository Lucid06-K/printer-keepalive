#!/bin/bash
# Copyright 2026 Lucid06-K
# SPDX-License-Identifier: Apache-2.0
#
# Printer Keep-Alive — release helper.
#
# One command to cut a release so the easy-to-forget steps can't be skipped:
# bump BOTH version sources, regenerate the checksum manifest, and — critically —
# SIGN it. An unsigned/mis-signed manifest makes `pkeep update` fail closed for
# EVERY user, so signing is mandatory: this script verifies the signature it just
# made and refuses to ship if anything is off.
#
# Usage:
#   ./release.sh 1.0.1 -m "fix: thing"   # full: bump → sign → commit → push
#   ./release.sh 1.0.1                    # prepare + sign + stage; you commit/push
#   ./release.sh --dry-run 1.0.1          # validate only; change nothing
#
# Signing key: $PKEEP_SIGNING_KEY, else ~/.config/printer-keepalive/update.md
# (see SIGNING.md). The key is plain PEM regardless of extension.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"; cd "$HERE"
SRC="$HERE/src"
CTL_SRC="$SRC/pkeep"                      # control script (carries VERSION + UPDATE_PUBKEY)
WORKER_SRC="$SRC/printer-keepalive.sh"    # the worker
SCRIPTS="$HOME/Library/Scripts"
KEY="${PKEEP_SIGNING_KEY:-$HOME/.config/printer-keepalive/update.md}"

BLD=$'\033[1m'; GRN=$'\033[32m'; YEL=$'\033[33m'; RED=$'\033[31m'; DIM=$'\033[2m'; R=$'\033[0m'
bold(){ printf '%s%s%s\n' "$BLD" "$1" "$R"; }
ok(){   printf '  %s✓%s %s\n' "$GRN" "$R" "$1"; }
info(){ printf '  %s• %s%s\n' "$DIM" "$1" "$R"; }
warn(){ printf '  %s! %s%s\n' "$YEL" "$1" "$R"; }
die(){  printf '  %s✗ %s%s\n' "$RED" "$1" "$R" >&2; exit 1; }
usage(){ sed -n '5,18p' "$0" | sed 's/^# \{0,1\}//'; }

ver_gt(){ [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" = "$1" ]; }

# --- args ------------------------------------------------------------------
DRY=0; MSG=""; NEW=""
while [ $# -gt 0 ]; do
    case "$1" in
        -n|--dry-run) DRY=1 ;;
        -m|--message) shift; MSG="${1:-}" ;;
        -h|--help)    usage; exit 0 ;;
        -*)           die "unknown option: $1 (try --help)" ;;
        *)            [ -z "$NEW" ] && NEW="$1" || die "unexpected argument: $1" ;;
    esac
    shift
done

# --- preconditions ---------------------------------------------------------
[ -f "$CTL_SRC" ] && [ -f "$WORKER_SRC" ] || die "run me from the repo root (src/ not found)"
command -v openssl >/dev/null 2>&1 || die "openssl not found"
command -v shasum  >/dev/null 2>&1 || die "shasum not found"
[ -n "$NEW" ] || { usage; exit 1; }
printf '%s' "$NEW" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || die "version must be x.y.z (got: $NEW)"

CUR=$(grep -m1 '^VERSION=' "$CTL_SRC" | cut -d'"' -f2)
[ -n "$CUR" ] || die "couldn't read current VERSION from src/pkeep"
ver_gt "$NEW" "$CUR" || die "new version $NEW is not greater than current $CUR"
[ -r "$KEY" ] || die "signing key not found at $KEY — set PKEEP_SIGNING_KEY or see SIGNING.md"

bold "Releasing Printer Keep-Alive  v$CUR → v$NEW"
info "signing key: $KEY"
[ "$DRY" = 1 ] && info "DRY RUN — nothing will be changed, signed, or pushed"

# --- 1. bump both version sources -----------------------------------------
if [ "$DRY" = 0 ]; then
    sed -i '' 's/^VERSION="[^"]*"/VERSION="'"$NEW"'"/' "$CTL_SRC"
    printf '%s\n' "$NEW" > "$HERE/VERSION"
    ok "VERSION bumped in src/pkeep and repo-root VERSION"
else
    info "would bump VERSION → $NEW (src/pkeep + repo-root VERSION)"
fi

# --- 2. syntax check -------------------------------------------------------
bash -n "$CTL_SRC"    || die "syntax error in src/pkeep"
bash -n "$WORKER_SRC" || die "syntax error in src/printer-keepalive.sh"
ok "bash -n syntax check passed"

# --- 3. regenerate + sign the manifest (the step you must never forget) ----
if [ "$DRY" = 1 ]; then man="$(mktemp)"; sig="$man.sig"; else man="$HERE/SHA256SUMS"; sig="$HERE/SHA256SUMS.sig"; fi
# explicit names (not *) so the manifest lists exactly what the updater fetches
( cd "$SRC" && shasum -a 256 printer-keepalive.sh pkeep > "$man" )
openssl dgst -sha256 -sign "$KEY" -out "$sig" "$man"

# self-check: the signature we just made must verify with the key's own pubkey
pub=$(openssl pkey -in "$KEY" -pubout 2>/dev/null) || die "couldn't derive public key from $KEY"
printf '%s\n' "$pub" > "$HERE/.relpub.tmp"
if ! openssl dgst -sha256 -verify "$HERE/.relpub.tmp" -signature "$sig" "$man" >/dev/null 2>&1; then
    rm -f "$HERE/.relpub.tmp"; [ "$DRY" = 1 ] && rm -f "$man" "$sig"; die "signature self-check FAILED — not shipping"
fi
rm -f "$HERE/.relpub.tmp"

# cross-check: signing key vs the public key baked into the client.
emb=$(awk '/^UPDATE_PUBKEY="/{f=1;sub(/^UPDATE_PUBKEY="/,"");print;next} f{print; if(/-----END PUBLIC KEY-----"$/)exit}' "$CTL_SRC" | sed 's/"$//')
if [ "$emb" != "$pub" ]; then
    warn "signing key ≠ UPDATE_PUBKEY in the client — clients will REJECT this release"
    warn "(expected only during a key rotation handoff; see SIGNING.md)"
fi

if [ "$DRY" = 1 ]; then
    rm -f "$man" "$sig"
    ok "signing validated (key OK · signature verifies · matches client key)"
else
    ok "SHA256SUMS regenerated and signed (SHA256SUMS.sig) — signature verified"
fi

# --- 4. sync the live copy on THIS machine (optional) ----------------------
if [ -f "$SCRIPTS/pkeep" ]; then
    if [ "$DRY" = 0 ]; then
        install -m 0755 "$WORKER_SRC" "$SCRIPTS/printer-keepalive.sh"
        install -m 0755 "$CTL_SRC"    "$SCRIPTS/pkeep"
        ok "live copy in ~/Library/Scripts synced"
    else
        info "would sync live copy in ~/Library/Scripts"
    fi
else
    info "no live install on this machine — skipping live sync"
fi

# --- 5. dry run stops here -------------------------------------------------
if [ "$DRY" = 1 ]; then
    bold "Dry run OK — v$NEW would be valid. Re-run without --dry-run to cut it."
    exit 0
fi

# --- 6. stage, guard against key material, commit + push -------------------
git add -A
if git diff --cached --name-only | grep -iqE '\.(key|pem)$|/?update\.(key|md)$'; then
    die "refusing to commit — signing-key material is staged (check .gitignore)"
fi
[ -s "$HERE/SHA256SUMS.sig" ] || die "SHA256SUMS.sig missing — refusing to commit an unsigned release"
ok "staged release files (no key material)"

if [ -n "$MSG" ]; then
    git commit -m "$MSG"
    git push
    bold "Released v$NEW ✓  (committed + pushed)"
    info "CDN can lag ~5 min before 'pkeep update' sees it."
else
    bold "Prepared & signed v$NEW — staged but not committed."
    printf '    review:  git diff --cached --stat\n'
    printf '    ship:    git commit -m "…" && git push\n'
fi
