#!/usr/bin/env bash
# Environment + artefact self-check for dsh-ubutu-icon.
#
# It verifies the repo is complete and loadable, runs the plugin test suite, and
# installs the desktop launcher into a THROWAWAY $HOME so the menu entry, the
# icon theme install and the uninstall path are exercised without touching the
# real desktop. The live DSH installation is only ever read, never modified.
#
#   tests/selfcheck.sh            # everything
#   tests/selfcheck.sh --quick    # skip the throwaway-HOME launcher install
set -uo pipefail

SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -- "$SELF_DIR/.." && pwd)"
QUICK=0
[ "${1:-}" = "--quick" ] && QUICK=1

PASS=0; FAIL=0; SKIP=0
ok()   { printf '  [PASS] %s\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '  [FAIL] %s\n' "$*"; FAIL=$((FAIL+1)); }
skip() { printf '  [SKIP] %s\n' "$*"; SKIP=$((SKIP+1)); }
have() { command -v "$1" >/dev/null 2>&1; }

TMP="$(mktemp -d)"
cleanup() { rm -rf -- "$TMP"; }
trap cleanup EXIT

printf '\ndsh-ubutu-icon — selfcheck\n'
printf '  repo: %s\n\n' "$ROOT"

echo "== repo layout"
for f in package.json cordis.patch.yml lib/index.js assets/knot.svg assets/icon.png \
         assets/dsh-badge.png desktop/dsh-ubuntu-icon.sh desktop/dsh-ubuntu-icon.svg \
         tools/install.sh tools/restore.sh tools/build-icons.sh tests/plugin.test.mjs \
         README.md README.en.md LICENSE; do
  [ -s "$ROOT/$f" ] && ok "$f" || bad "$f missing or empty"
done

echo "== manifest"
if node -e 'const p=require(process.argv[1]);process.exit(p.name==="dsh-ubutu-icon"&&p.type==="module"&&p.dsh?.bundle?.patch?0:1)' "$ROOT/package.json" 2>/dev/null; then
  ok "package.json: name/type/dsh.bundle.patch"
else
  bad "package.json manifest wrong"
fi
if node -e 'const fs=require("node:fs");const p=require(process.argv[1]);process.exit(fs.existsSync(require("node:path").join(process.argv[2],p.dsh.bundle.patch))?0:1)' "$ROOT/package.json" "$ROOT" 2>/dev/null; then
  ok "dsh.bundle.patch resolves to a real file"
else
  bad "dsh.bundle.patch does not resolve"
fi
grep -q 'id: ubuntu-icon' "$ROOT/cordis.patch.yml" && ok "cordis.patch.yml inserts id ubuntu-icon" || bad "cordis.patch.yml insert missing"

echo "== sources"
for f in lib/index.js tools/install.sh tools/restore.sh tools/build-icons.sh desktop/dsh-ubuntu-icon.sh tests/selfcheck.sh; do
  bash -n "$ROOT/$f" 2>/dev/null || node --check "$ROOT/$f" 2>/dev/null && ok "syntax: $f" || bad "syntax: $f"
done
grep -q 'KNOT\|knot.svg' "$ROOT/lib/index.js" && ok "plugin reads the shipped knot artwork" || bad "plugin knot wiring missing"

echo "== icons"
"$ROOT/tools/build-icons.sh" --check >/dev/null 2>&1 && ok "hicolor PNG set + scalable SVG present" || bad "icon set incomplete (run tools/build-icons.sh)"
if have identify; then
  sizes="$(for f in "$ROOT"/desktop/icons/hicolor/*/apps/dsh-ubuntu-icon.png; do identify -format '%wx%h ' "$f"; done)"
  ok "icon geometries: $sizes"
else
  skip "ImageMagick not installed (geometry check)"
fi
if have rsvg-convert || have convert; then
  svg_ok=1
  head -c 200 "$ROOT/desktop/dsh-ubuntu-icon.svg" | grep -q '<svg' || svg_ok=0
  grep -q '#1E6FEB' "$ROOT/desktop/dsh-ubuntu-icon.svg" || svg_ok=0
  [ "$svg_ok" = 1 ] && ok "menu SVG is valid-looking and uses #1E6FEB" || bad "menu SVG malformed"
else
  skip "no SVG rasteriser (SVG content check)"
fi

echo "== plugin test suite"
if node "$ROOT/tests/plugin.test.mjs" >"$TMP/plugin.log" 2>&1; then
  ok "$(tail -n 1 "$TMP/plugin.log" | tr -d '=')"
else
  bad "plugin.test.mjs failed:"; sed 's/^/        /' "$TMP/plugin.log" | grep -E 'FAIL' | head -5
fi

echo "== installer (sandboxed DSH_HOME)"
SANDBOX="$TMP/dsh-home"
mkdir -p "$SANDBOX/profiles/web"
printf '{"name":"sandbox","private":true,"dependencies":{},"dsh":{"profile":{"bundles":[]}}}\n' > "$SANDBOX/profiles/web/package.json"
if DSH_HOME="$SANDBOX" "$ROOT/tools/install.sh" install >"$TMP/install.log" 2>&1; then
  ok "install.sh install"
else
  bad "install.sh install failed"; sed 's/^/        /' "$TMP/install.log" | tail -3
fi
[ -f "$SANDBOX/local-plugins/dsh-ubutu-icon/lib/index.js" ] && ok "plugin copied into local-plugins" || bad "plugin copy missing"
[ -e "$SANDBOX/profiles/web/node_modules/dsh-ubutu-icon" ] && ok "linked into profile node_modules" || bad "node_modules link missing"
node -e 'const p=require(process.argv[1]);const b=(p.dsh.profile.bundles||[]);process.exit(p.dependencies["dsh-ubutu-icon"]&&b.includes("dsh-ubutu-icon")?0:1)' \
  "$SANDBOX/profiles/web/package.json" 2>/dev/null \
  && ok "registered in dependencies + bundles" || bad "registration incomplete"
DSH_HOME="$SANDBOX" "$ROOT/tools/install.sh" status >"$TMP/status.log" 2>&1 \
  && grep -q 'in bundles    : yes' "$TMP/status.log" && ok "install.sh status" || bad "install.sh status wrong"
DSH_HOME="$SANDBOX" "$ROOT/tools/install.sh" uninstall >/dev/null 2>&1 \
  && node -e 'const p=require(process.argv[1]);process.exit(Object.keys(p.dependencies).length===0&&p.dsh.profile.bundles.length===0?0:1)' \
       "$SANDBOX/profiles/web/package.json" 2>/dev/null \
  && ok "uninstall leaves the profile clean" || bad "uninstall did not restore the profile"

echo "== restore tool"
out="$(DSH_HOME="$SANDBOX" "$ROOT/tools/restore.sh" 2>&1)"; rc=$?
case "$out" in
  *"no backups"*) ok "restore.sh reports 'nothing to restore' honestly (exit $rc)" ;;
  *) bad "restore.sh did not report the empty state: $(printf '%s' "$out" | tail -1)" ;;
esac
# (b) real round-trip: fabricate a backup + manifest exactly as the plugin writes it
BR="$SANDBOX/ubuntu-icon-data/backup/9.9.9"
mkdir -p "$BR" "$TMP/targetdir"
BN="$(printf '%s' "$TMP/targetdir/favicon.svg" | sed 's#[/\\:*?"<>|]#_#g')"
printf 'STOCK-CONTENT\n' > "$BR/$BN"
printf 'PATCHED-CONTENT\n' > "$TMP/targetdir/favicon.svg"
node -e '
  const fs=require("node:fs"),crypto=require("node:crypto"),path=require("node:path");
  const [dir,target,backupName]=process.argv.slice(1);
  const stock=fs.readFileSync(path.join(dir,backupName));
  fs.writeFileSync(path.join(dir,"manifest.json"),JSON.stringify({[backupName]:{target,sha256:crypto.createHash("sha256").update(stock).digest("hex"),at:new Date().toISOString()}},null,2));
' "$BR" "$TMP/targetdir/favicon.svg" "$BN"
if DSH_HOME="$SANDBOX" "$ROOT/tools/restore.sh" >"$TMP/restore1.log" 2>&1 && grep -q 'would restore' "$TMP/restore1.log"; then
  ok "restore.sh dry-run lists the file it would put back"
else
  bad "restore.sh dry-run wrong: $(tail -1 "$TMP/restore1.log" 2>/dev/null)"
fi
if [ "$(cat "$TMP/targetdir/favicon.svg")" = "PATCHED-CONTENT" ]; then
  ok "dry-run did not touch the file"
else
  bad "dry-run modified the file"
fi
if DSH_HOME="$SANDBOX" "$ROOT/tools/restore.sh" --yes >"$TMP/restore2.log" 2>&1 && [ "$(cat "$TMP/targetdir/favicon.svg")" = "STOCK-CONTENT" ]; then
  ok "restore.sh --yes puts the stock bytes back"
else
  bad "restore.sh --yes failed: $(tail -1 "$TMP/restore2.log" 2>/dev/null)"
fi
# NOTE: capture to a file instead of piping into `grep -q`. With `pipefail` set,
# grep exiting early on a match can SIGPIPE the script upstream and fail the test
# even though the behaviour is correct.
DSH_HOME="$SANDBOX" "$ROOT/tools/restore.sh" --yes >"$TMP/restore3.log" 2>&1
if grep -q 'already stock' "$TMP/restore3.log"; then
  ok "restore.sh is idempotent (second run detects stock)"
else
  bad "restore.sh is not idempotent"
fi

if [ "$QUICK" = 0 ]; then
  echo "== desktop launcher (throwaway HOME)"
  FH="$TMP/home"
  mkdir -p "$FH"
  if HOME="$FH" DSH_NO_DIALOG=1 "$ROOT/desktop/dsh-ubuntu-icon.sh" install >"$TMP/launcher.log" 2>&1; then
    ok "launcher install"
  else
    bad "launcher install failed"; sed 's/^/        /' "$TMP/launcher.log" | tail -4
  fi
  DE="$FH/.local/share/applications/dsh-ubuntu-icon.desktop"
  [ -f "$DE" ] && ok "desktop entry written" || bad "desktop entry missing"
  [ -x "$FH/.local/bin/dsh-ubuntu-icon" ] && ok "launcher binary installed" || bad "launcher binary missing"
  [ -s "$FH/.local/share/icons/hicolor/scalable/apps/dsh-ubuntu-icon.svg" ] && ok "scalable icon installed" || bad "scalable icon missing"
  png_count=$(find "$FH/.local/share/icons/hicolor" -name 'dsh-ubuntu-icon.png' 2>/dev/null | wc -l)
  [ "$png_count" -ge 8 ] && ok "raster icons installed ($png_count sizes)" || bad "expected >=8 raster icons, got $png_count"
  if have desktop-file-validate; then
    out="$(desktop-file-validate "$DE" 2>&1)"
    [ -z "$out" ] && ok "desktop-file-validate clean" || bad "desktop-file-validate: $out"
  else
    skip "desktop-file-validate not installed"
  fi
  grep -q '^Exec=' "$DE" && ok "entry has an Exec line" || bad "entry has no Exec"
  HOME="$FH" "$ROOT/desktop/dsh-ubuntu-icon.sh" uninstall >/dev/null 2>&1
  [ ! -f "$DE" ] && ok "launcher uninstall removes the entry" || bad "entry survived uninstall"
  left=$(find "$FH/.local/share/icons/hicolor" -name 'dsh-ubuntu-icon.*' 2>/dev/null | wc -l)
  [ "$left" = 0 ] && ok "launcher uninstall removes the icons" || bad "$left icons survived uninstall"
else
  skip "desktop launcher install (--quick)"
fi

echo "== live installation (read-only)"
LIVE="$(find "$HOME/.npm/_npx" /usr/lib/node_modules /usr/local/lib/node_modules \
        -maxdepth 5 -path '*@deepseek-ai/dsh-web-frontend/dist' -type d 2>/dev/null | head -1)"
if [ -n "$LIVE" ]; then
  ok "found a live frontend: $LIVE"
  if [ -f "$LIVE/favicon.svg" ] && cmp -s "$LIVE/favicon.svg" "$ROOT/assets/knot.svg"; then
    ok "live favicon is currently the blue knot"
  else
    skip "live favicon is still stock (plugin not applied yet on this machine)"
  fi
  log="$HOME/.dsh/ubuntu-icon-data/ubuntu-icon.log"
  [ -f "$log" ] && ok "repair log exists ($(wc -l <"$log") lines)" || skip "no repair log yet"
else
  skip "no live frontend found on this machine"
fi

printf '\n== selfcheck: %d passed, %d failed, %d skipped ==\n\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" = 0 ]
