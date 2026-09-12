#!/usr/bin/env bash
# Install / uninstall the dsh-ubutu-icon plugin for the local DSH harness.
#
# Linux counterpart of the upstream Windows `tools/install.ps1`: it copies the
# package into <DSH_HOME>/local-plugins, registers it in the profile's
# package.json (dependencies + dsh.profile.bundles) and links it into that
# profile's node_modules so the loader can resolve it by name.
#
#   tools/install.sh [install]            # default: install for the current user
#   tools/install.sh status               # show what is registered where
#   tools/install.sh uninstall [--purge]  # deregister (--purge also deletes the copy)
#
# Options: --profile <name> (default: web or $DSH_PROFILE), --copy (copy instead
# of symlink into node_modules), --dry-run.
set -euo pipefail

NAME="dsh-ubutu-icon"
SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$(cd -- "$SELF_DIR/.." && pwd)"
DSH_HOME="${DSH_HOME:-$HOME/.dsh}"
PROFILE="${DSH_PROFILE:-web}"
ACTION="install"
MODE="link"
DRY=0
PURGE=0

say()  { printf '  %s\n' "$*"; }
warn() { printf '  ! %s\n' "$*" >&2; }
die()  { printf 'install.sh: %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    install|uninstall|status) ACTION="$1" ;;
    --profile) shift; PROFILE="${1:-}"; [ -n "$PROFILE" ] || die "--profile needs a value" ;;
    --copy) MODE="copy" ;;
    --link) MODE="link" ;;
    --purge) PURGE=1 ;;
    --dry-run) DRY=1 ;;
    -h|--help) sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
  shift
done

PLUGIN_DIR="$DSH_HOME/local-plugins/$NAME"
PROFILE_DIR="$DSH_HOME/profiles/$PROFILE"
PROFILE_PKG="$PROFILE_DIR/package.json"
LINK_PATH="$PROFILE_DIR/node_modules/$NAME"

command -v node >/dev/null 2>&1 || die "node is required (dsh itself needs it)"

# The profile package.json edit is done in node: it must stay valid JSON and the
# bundles order is meaningful, so a blind text append would be wrong.
edit_profile() { # edit_profile <add|remove>
  local op="$1"
  node -e '
    const fs = require("node:fs");
    const [op, pkgPath, name, dir] = process.argv.slice(1);
    const pkg = JSON.parse(fs.readFileSync(pkgPath, "utf8"));
    pkg.dependencies ??= {};
    pkg.dsh ??= {}; pkg.dsh.profile ??= {}; pkg.dsh.profile.bundles ??= [];
    if (op === "add") {
      pkg.dependencies[name] = `file:${dir}`;
      if (!pkg.dsh.profile.bundles.includes(name)) pkg.dsh.profile.bundles.push(name);
    } else {
      delete pkg.dependencies[name];
      pkg.dsh.profile.bundles = pkg.dsh.profile.bundles.filter((b) => b !== name);
    }
    fs.writeFileSync(pkgPath, JSON.stringify(pkg, null, 2) + "\n");
  ' "$op" "$PROFILE_PKG" "$NAME" "$PLUGIN_DIR"
}

do_status() {
  printf '\n%s — status\n' "$NAME"
  say "DSH_HOME      : $DSH_HOME"
  say "profile       : $PROFILE ($PROFILE_PKG)"
  if [ -d "$PLUGIN_DIR" ]; then say "package copy  : present ($PLUGIN_DIR)"; else say "package copy  : absent"; fi
  if [ -e "$LINK_PATH" ]; then say "node_modules  : present ($LINK_PATH)"; else say "node_modules  : absent"; fi
  if [ -f "$PROFILE_PKG" ]; then
    node -e '
      const pkg = require(process.argv[1]);
      const dep = (pkg.dependencies ?? {})[process.argv[2]];
      const listed = ((pkg.dsh ?? {}).profile ?? {}).bundles ?? [];
      console.log(`  dependency    : ${dep ?? "(not registered)"}`);
      console.log(`  in bundles    : ${listed.includes(process.argv[2]) ? "yes" : "no"}`);
    ' "$PROFILE_PKG" "$NAME" || warn "could not read $PROFILE_PKG"
  else
    warn "no profile package.json at $PROFILE_PKG (choose one with --profile)"
  fi
  local log="$DSH_HOME/ubuntu-icon-data/ubuntu-icon.log"
  if [ -f "$log" ]; then say "last repair   : $(tail -n 1 "$log")"; else say "last repair   : (no log yet)"; fi
}

do_install() {
  [ -f "$SRC_DIR/package.json" ] || die "not a plugin package: $SRC_DIR"
  [ -f "$PROFILE_PKG" ] || die "profile not found: $PROFILE_PKG (use --profile <name>)"

  if [ "$DRY" = 1 ]; then
    say "dry-run: would copy $SRC_DIR -> $PLUGIN_DIR"
    say "dry-run: would register '$NAME' in $PROFILE_PKG and link $LINK_PATH"
    return 0
  fi

  mkdir -p "$DSH_HOME/local-plugins" "$PROFILE_DIR/node_modules"
  rm -rf -- "$PLUGIN_DIR"
  mkdir -p -- "$PLUGIN_DIR"
  # Ship only what the loader needs; the desktop/ and tools/ halves stay in the repo.
  # Ship only what the loader needs; the desktop/ and tools/ halves stay in the repo.
  local item
  for item in lib assets cordis.patch.yml package.json README.md LICENSE; do
    [ -e "$SRC_DIR/$item" ] && cp -r -- "$SRC_DIR/$item" "$PLUGIN_DIR/"
  done
  [ -f "$PLUGIN_DIR/lib/index.js" ] || die "copy failed: $PLUGIN_DIR/lib/index.js missing"
  say "package  → $PLUGIN_DIR"

  cp -f -- "$PROFILE_PKG" "$PROFILE_PKG.bak-$(date +%Y%m%d%H%M%S)"
  edit_profile add
  say "profile  → registered '$NAME' in $PROFILE_PKG"

  rm -rf -- "$LINK_PATH"
  if [ "$MODE" = "copy" ]; then
    cp -r -- "$PLUGIN_DIR" "$LINK_PATH"
    say "modules  → copied to $LINK_PATH"
  else
    ln -s -- "$PLUGIN_DIR" "$LINK_PATH"
    say "modules  → symlinked $LINK_PATH -> $PLUGIN_DIR"
  fi

  cat <<EOF

  Done. The plugin repairs the branding ~3s after every harness boot.

  Apply it now without restarting     : restart dsh web (or the DSH Desktop app)
  Check the result                    : tools/install.sh status
                                        tail -f $DSH_HOME/ubuntu-icon-data/ubuntu-icon.log
  Undo the files, keep the plugin     : tools/restore.sh --yes
  Remove the plugin                   : tools/install.sh uninstall

EOF
}

do_uninstall() {
  rm -rf -- "$LINK_PATH"
  say "modules  → removed $LINK_PATH"
  if [ -f "$PROFILE_PKG" ]; then
    cp -f -- "$PROFILE_PKG" "$PROFILE_PKG.bak-$(date +%Y%m%d%H%M%S)"
    edit_profile remove
    say "profile  → deregistered '$NAME'"
  fi
  if [ "$PURGE" = 1 ]; then
    rm -rf -- "$PLUGIN_DIR"
    say "package  → deleted $PLUGIN_DIR"
  else
    say "package  → kept $PLUGIN_DIR (use --purge to delete)"
  fi
  say "note     → patched files stay branded; undo with tools/restore.sh --yes"
}

case "$ACTION" in
  install)   do_install ;;
  uninstall) do_uninstall ;;
  status)    do_status ;;
esac
