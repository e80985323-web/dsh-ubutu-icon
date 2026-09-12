#!/usr/bin/env bash
# Put the STOCK files back, using the manifests the plugin wrote when it first
# patched them. This is the "I want my original DeepSeek branding back" button.
#
#   tools/restore.sh                 # dry run: show what would be put back
#   tools/restore.sh --yes           # actually restore (all versions)
#   tools/restore.sh --yes --version 0.1.5-rc.1
#
# Backups live in <DSH_HOME>/ubuntu-icon-data/backup/<frontend-version>/ and are
# never deleted by this script, so restoring is itself reversible.
set -euo pipefail

DSH_HOME="${DSH_HOME:-$HOME/.dsh}"
BACKUP_ROOT="$DSH_HOME/ubuntu-icon-data/backup"
YES=0
VERSION=""

say()  { printf '  %s\n' "$*"; }
die()  { printf 'restore.sh: %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --yes|-y) YES=1 ;;
    --version) shift; VERSION="${1:-}"; [ -n "$VERSION" ] || die "--version needs a value" ;;
    -h|--help) sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
  shift
done

command -v node >/dev/null 2>&1 || die "node is required"
[ -d "$BACKUP_ROOT" ] || die "no backups at $BACKUP_ROOT — nothing was ever patched on this machine"

PROGRAM='
const fs = require("node:fs");
const path = require("node:path");
const [root, onlyVersion, apply] = process.argv.slice(1);
const versions = fs.existsSync(root)
  ? fs.readdirSync(root).filter((v) => fs.statSync(path.join(root, v)).isDirectory())
  : [];
let restored = 0, missing = 0, skipped = 0;
for (const version of versions.sort()) {
  if (onlyVersion && version !== onlyVersion) continue;
  const dir = path.join(root, version);
  const manifestPath = path.join(dir, "manifest.json");
  if (!fs.existsSync(manifestPath)) { console.log(`  ! ${version}: no manifest.json (patched by an older version?)`); continue; }
  const manifest = JSON.parse(fs.readFileSync(manifestPath, "utf8"));
  const entries = Object.entries(manifest);
  console.log(`  ${version}: ${entries.length} file(s)`);
  for (const [file, meta] of entries) {
    const backup = path.join(dir, file);
    if (!fs.existsSync(backup)) { console.log(`      MISSING backup  ${meta.target}`); missing++; continue; }
    const current = fs.existsSync(meta.target) ? fs.readFileSync(meta.target) : null;
    const crypto = require("node:crypto");
    const hash = current ? crypto.createHash("sha256").update(current).digest("hex") : null;
    if (hash === meta.sha256) { console.log(`      already stock   ${meta.target}`); skipped++; continue; }
    if (apply) {
      fs.mkdirSync(path.dirname(meta.target), { recursive: true });
      fs.copyFileSync(backup, meta.target);
      console.log(`      restored        ${meta.target}`);
    } else {
      console.log(`      would restore   ${meta.target}`);
    }
    restored++;
  }
}
console.log(`\n  ${apply ? "restored" : "to restore"}: ${restored}   already stock: ${skipped}   missing backups: ${missing}`);
if (!apply && restored > 0) console.log("  re-run with --yes to apply");
'

printf '\n%s — restore stock branding\n' "dsh-ubutu-icon"
# NOTE: the flag must be EMPTY (not "0") when not applying — a non-empty string
# like "0" is truthy in JS, which would turn a dry run into a real restore.
APPLY=""
[ "$YES" = 1 ] && APPLY="1"
node -e "$PROGRAM" "$BACKUP_ROOT" "$VERSION" "$APPLY"
say "backups kept in $BACKUP_ROOT"
