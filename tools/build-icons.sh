#!/usr/bin/env bash
# Regenerate desktop/ icons from assets/icon.png (the upstream blue-knot artwork).
#
#   tools/build-icons.sh            # rebuild the hicolor PNG set + the menu SVG
#   tools/build-icons.sh --check    # verify they are present and non-empty
#
# Needs ImageMagick (`convert` or `magick`) only when regenerating; the built
# icons are committed, so end users never have to run this.
set -euo pipefail

SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$SELF_DIR/.." && pwd)"
SRC="$ROOT_DIR/assets/icon.png"
OUT="$ROOT_DIR/desktop/icons/hicolor"
SIZES=(16 24 32 48 64 128 256 512)

say() { printf '  %s\n' "$*"; }
die() { printf 'build-icons.sh: %s\n' "$*" >&2; exit 1; }

if [ "${1:-}" = "--check" ]; then
  rc=0
  for s in "${SIZES[@]}"; do
    f="$OUT/${s}x${s}/apps/dsh-ubuntu-icon.png"
    if [ -s "$f" ]; then say "ok   ${s}x${s}  $(stat -c%s "$f") bytes"
    else say "MISS ${s}x${s}  $f"; rc=1; fi
  done
  [ -s "$ROOT_DIR/desktop/dsh-ubuntu-icon.svg" ] && say "ok   scalable dsh-ubuntu-icon.svg" || { say "MISS desktop/dsh-ubuntu-icon.svg"; rc=1; }
  exit "$rc"
fi

[ -f "$SRC" ] || die "missing $SRC"
CONVERT=""
for c in convert magick; do command -v "$c" >/dev/null 2>&1 && { CONVERT="$c"; break; }; done
[ -n "$CONVERT" ] || die "ImageMagick not found (apt install imagemagick)"

# The knot marks are drawn on a transparent canvas; -background none keeps that,
# and -strip drops the source metadata so the PNGs stay reproducible.
for s in "${SIZES[@]}"; do
  d="$OUT/${s}x${s}/apps"
  mkdir -p "$d"
  "$CONVERT" "$SRC" -background none -resize "${s}x${s}" -strip "$d/dsh-ubuntu-icon.png"
  say "wrote ${s}x${s}  $(stat -c%s "$d/dsh-ubuntu-icon.png") bytes"
done

cp -f "$ROOT_DIR/assets/knot.svg" "$ROOT_DIR/desktop/dsh-ubuntu-icon.svg"
say "wrote scalable desktop/dsh-ubuntu-icon.svg"
