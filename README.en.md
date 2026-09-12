# dsh-ubutu-icon

Keeps the **blue hollow ChatGPT-knot** branding (`#1E6FEB`) on the DSH web UI and
**re-applies it after every DSH / npm update**.

Ubuntu / Linux port of [`dsh-gpt-icon`](https://github.com/e80985323-web/dsh-gpt-icon) (Windows).

Two halves, install either or both:

| Half | What it does | Carrier |
| --- | --- | --- |
| **Icon plugin** | favicon, in-app `FishLogo`, `BrandWordmark`, skill badge → blue knot | DSH plugin (`lib/index.js`), repairs ~3 s after every boot |
| **Desktop launcher** | a blue-knot entry in the menu/dock that opens the DSH Web GUI | `.desktop` + hicolor icons + pure-bash launcher |

## Why the Linux port is not a copy-paste of the Windows one

The Windows version patches the EXE icon, splash GIFs and tray icon inside
`D:\dsh desktop\resources\...`. **None of that exists on Ubuntu**, so a naive port
would report "file missing" for almost every target. What is actually true here:

- **DSH Desktop ships as an AppImage and does not bundle the web UI.** Measured
  process tree: AppImage (Electron) → `npm exec @deepseek-ai/dsh web --port 3080`.
  The page you look at is served from `node_modules/@deepseek-ai/dsh-web-frontend/dist`
  inside the npm/npx cache. That directory is **writable**, so the branding lives
  there — and since an npx re-install replaces it wholesale, that is exactly why
  the plugin has to repair after updates, same as on Windows.
- **There is no EXE-embedded icon.** The AppImage is a read-only squashfs; the
  Linux equivalent of "window/tray icon" is the **desktop entry** (user-level
  `.desktop` + hicolor icon), which application updates do not overwrite.
- Splash GIFs, `dsh-desktop-logo*.png` and `dsh-client-ui-primitives` do not exist
  in the Linux package. A missing target is reported as `skipped`, never as an error.

The plugin patches **the frontend the running process actually serves** (resolved
from the live process paths first), instead of guessing a directory.

## Install

### 1. Icon plugin (web UI)

```bash
git clone https://github.com/e80985323-web/dsh-ubutu-icon.git
cd dsh-ubutu-icon
tools/install.sh          # copy to <DSH_HOME>/local-plugins and register it
tools/install.sh status    # verify
```

Restart DSH (or the DSH Desktop app); the branding is in place ~3 s later.
Options: `--profile <name>` (default `web`), `--copy`, `--dry-run`.

### 2. Desktop launcher

```bash
desktop/dsh-ubuntu-icon.sh install            # ~/.local, no sudo
desktop/dsh-ubuntu-icon.sh install --system   # /usr/local, needs sudo
desktop/dsh-ubuntu-icon.sh check              # environment self-check
```

## Manual control

| Entry point | Meaning |
| --- | --- |
| `GET /ubuntu-icon/status` | JSON result of the last repair, per target |
| `GET /ubuntu-icon/repair` | repair right now, returns the same JSON |
| `DSH_UBUNTU_ICON_ROOT=<pkg dir>` | **pin** one target and disable auto-discovery |

Log: `~/.dsh/ubuntu-icon-data/ubuntu-icon.log`.

## Undo

```bash
tools/restore.sh          # dry run
tools/restore.sh --yes    # put the stock files back (from manifest.json)
tools/install.sh uninstall [--purge]
desktop/dsh-ubuntu-icon.sh uninstall
```

Backups live in `~/.dsh/ubuntu-icon-data/backup/<frontend-version>/` together with a
`manifest.json` holding each original path and sha256; backups are never deleted,
so restoring is itself reversible.

## How the patch works

- **Files** (favicon, badge PNG): compared by sha256, backed up once, then copied.
- **Text** (badge shields.io link): marker-checked, `logo=deepseek` → `logo=openai&logoColor=1E6FEB`.
- **Minified bundle**: it does **not** hardcode minifier output. It reads the
  `FishLogo:<alias>` export, bounds the function by bracket matching, normalises
  the `viewBox` to `24 24`, swaps the path for the knot and scales the wordmark
  whale's replacement into the whale's original 23.16 × 17.04 box. A `node --check`
  failure rolls the file back automatically.

## Tests

```bash
node tests/plugin.test.mjs   # 22 checks: routes, patching, idempotency, backup, restore, log
tests/selfcheck.sh           # environment + artefact self-check
```

The test uses a real installed frontend as its fixture when available and runs
entirely inside a temp directory — it can never patch the live installation
(guaranteed by pinning via `DSH_UBUNTU_ICON_ROOT`, and verified: after a test run
the live favicon and bundle sha256 are unchanged).

## Disclaimer

Unofficial, not affiliated with DeepSeek. It modifies local files of
`@deepseek-ai/dsh-web-frontend` inside your npm cache. Everything is backed up and
reversible, but use at your own risk.

## License

MIT — see [LICENSE](LICENSE). Upstream Windows version:
<https://github.com/e80985323-web/dsh-gpt-icon>
