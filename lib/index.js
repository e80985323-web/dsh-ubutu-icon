/**
 * dsh-ubutu-icon — host half (Ubuntu / Linux port of `dsh-gpt-icon`).
 *
 * Keeps the blue hollow ChatGPT-knot branding (#1E6FEB) on the DSH Web UI and
 * re-applies it after every harness / npm update.
 *
 * Why the Linux half looks different from the Windows original
 * -----------------------------------------------------------
 * On Windows the branding lives inside `D:\dsh desktop\resources\...`. On Linux
 * the DSH Desktop AppImage does *not* bundle the web UI: it spawns
 * `npm exec @deepseek-ai/dsh web`, and the page you actually look at is served
 * from `node_modules/@deepseek-ai/dsh-web-frontend/dist` inside the npm/npx
 * cache. That directory is writable, so the branding can live there — and
 * because an npx re-install replaces it wholesale, this plugin repairs it on
 * every boot (exactly the "update overwrote my branding" model of the original).
 *
 * What gets patched (every target is optional; a missing one is reported as
 * `skipped` instead of failing):
 *
 *   - dsh-web-frontend/dist/favicon.svg          blue hollow knot
 *   - dsh-web-frontend/dist/assets/index-*.js    FishLogo component and the
 *                                                BrandWordmark whale -> knot
 *   - dsh-skill-badge/assets/dsh-badge.png       badge artwork
 *   - dsh-skill-badge/assets/dsh-badge.md        shields.io logo=deepseek -> openai
 *
 * Everything is idempotent (hash / marker checked) and every modified file is
 * backed up once per frontend version under `<DSH_HOME>/ubuntu-icon-data/backup/`.
 *
 * Routes: GET /ubuntu-icon/status, GET /ubuntu-icon/repair
 */
import { createHash } from "node:crypto";
import { existsSync } from "node:fs";
import { appendFile, copyFile, mkdir, readFile, readdir, writeFile } from "node:fs/promises";
import { spawnSync } from "node:child_process";
import { createRequire } from "node:module";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const pluginRoot = dirname(dirname(fileURLToPath(import.meta.url)));
const BLUE = "#1E6FEB";

const name = "dsh-ubutu-icon";
const inject = ["webServer"];

const ROUTE_STATUS = "/ubuntu-icon/status";
const ROUTE_REPAIR = "/ubuntu-icon/repair";

// ------------------------------------------------------------------ helpers

function dshHome() {
  return process.env.DSH_HOME || join(homedir(), ".dsh");
}

function dataDir() {
  return join(dshHome(), "ubuntu-icon-data");
}

async function log(message) {
  const line = `[${new Date().toISOString()}] [${name}] ${message}\n`;
  try {
    await mkdir(dataDir(), { recursive: true });
    await appendFile(join(dataDir(), "ubuntu-icon.log"), line);
  } catch {
    /* logging is best effort */
  }
}

function sha256(buffer) {
  return createHash("sha256").update(buffer).digest("hex");
}

function safeName(path) {
  return path.replace(/[/\\:*?"<>|]/g, "_");
}

async function readJson(path) {
  try {
    return JSON.parse(await readFile(path, "utf8"));
  } catch {
    return null;
  }
}

async function safeReaddir(path) {
  try {
    return await readdir(path);
  } catch {
    return [];
  }
}

/**
 * Copy a file aside once per frontend version, and record where it came from.
 * The manifest is what `tools/restore.sh` replays, so an uninstall can put the
 * stock files back byte-for-byte instead of guessing from the backup name.
 */
async function backupOnce(target, version) {
  if (!existsSync(target)) return null;
  const dir = join(dataDir(), "backup", version || "unknown");
  const destination = join(dir, safeName(target));
  if (!existsSync(destination)) {
    await mkdir(dir, { recursive: true });
    await copyFile(target, destination);
    const manifestPath = join(dir, "manifest.json");
    const manifest = (await readJson(manifestPath)) || {};
    manifest[safeName(target)] = {
      target,
      sha256: sha256(await readFile(target)),
      at: new Date().toISOString()
    };
    await writeFile(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`, "utf8");
  }
  return destination;
}

/** The shipped artwork is the single source of truth for the knot geometry. */
async function readKnot() {
  const svg = await readFile(join(pluginRoot, "assets", "knot.svg"), "utf8");
  const pathMatch = /<path[^>]*\sd="([^"]+)"/.exec(svg);
  const fillMatch = /<path[^>]*\sfill="([^"]+)"/.exec(svg);
  if (!pathMatch) throw new Error("assets/knot.svg: no <path d=...> found");
  return { svg, path: pathMatch[1], fill: fillMatch ? fillMatch[1] : BLUE };
}

// ------------------------------------------------------- frontend discovery

/**
 * Find every `@deepseek-ai/dsh-web-frontend/dist` this machine could be serving.
 * The most trustworthy source is the running process itself (the plugin runs
 * inside the very process that serves the page), so that is tried first.
 */
async function findFrontendDists() {
  const found = new Map(); // dist -> { dist, source, nodeModules }

  const add = async (dist, source) => {
    if (!dist || found.has(dist)) return;
    if (!existsSync(join(dist, "favicon.svg")) && !existsSync(join(dist, "index.html"))) return;
    try {
      const real = await import("node:fs/promises").then((fs) => fs.realpath(dist));
      if (found.has(real)) return;
      found.set(real, {
        dist: real,
        source,
        // dist = <node_modules>/@deepseek-ai/dsh-web-frontend/dist
        nodeModules: dirname(dirname(dirname(real)))
      });
    } catch {
      /* unreadable candidate */
    }
  };

  const rel = join("node_modules", "@deepseek-ai", "dsh-web-frontend", "dist");

  // 1) explicit override — this PINS the target: nothing else is touched, so a
  //    test (or a user pinning one profile) can never patch an install it did
  //    not name. Auto-discovery below runs only when no override is given.
  const override = process.env.DSH_UBUNTU_ICON_ROOT;
  if (override) {
    await add(override, "DSH_UBUNTU_ICON_ROOT");
    await add(join(override, "dist"), "DSH_UBUNTU_ICON_ROOT/dist");
    await add(join(override, rel), "DSH_UBUNTU_ICON_ROOT/node_modules");
    return [...found.values()];
  }

  // 2) module resolution as seen from this plugin
  try {
    const require = createRequire(import.meta.url);
    const pkg = require.resolve("@deepseek-ai/dsh-web-frontend/package.json");
    await add(join(dirname(pkg), "dist"), "require.resolve");
  } catch {
    /* not resolvable from the plugin's own tree — expected under npx */
  }

  // 3) walk up from the running dsh entry point and from node itself
  for (const [start, why] of [
    [process.argv[1], "process.argv[1]"],
    [process.execPath, "process.execPath"]
  ]) {
    if (!start) continue;
    let dir = dirname(start);
    for (let depth = 0; depth < 10; depth++) {
      await add(join(dir, rel), why);
      const parent = dirname(dir);
      if (parent === dir) break;
      dir = parent;
    }
  }

  // 4) known install roots (npx cache, global npm prefixes, this repo's dev tree)
  const roots = [
    join(homedir(), ".npm", "_npx"),
    join(homedir(), ".local", "share", "npm", "lib"),
    join(homedir(), ".local", "lib"),
    "/usr/local/lib",
    "/usr/lib",
    join(pluginRoot, "node_modules")
  ];
  for (const root of roots) {
    await add(join(root, rel), root);
    for (const entry of await safeReaddir(root)) {
      await add(join(root, entry, rel), `${root}/${entry}`);
    }
  }

  return [...found.values()];
}

async function frontendVersion(dist) {
  const pkg = await readJson(join(dirname(dist), "package.json"));
  return (pkg && pkg.version) || "unknown";
}

// ------------------------------------------------------------ patch engines

async function applyFileOp(item, version, results) {
  if (!existsSync(item.target)) {
    results.push({ name: item.name, state: "skipped", detail: "target missing (layout changed?)" });
    return;
  }
  const assetPath = join(pluginRoot, "assets", item.asset);
  const [targetHash, assetHash] = await Promise.all([
    readFile(item.target).then(sha256),
    readFile(assetPath).then(sha256)
  ]);
  if (targetHash === assetHash) {
    results.push({ name: item.name, state: "ok", detail: "already applied" });
    return;
  }
  await backupOnce(item.target, version);
  await copyFile(assetPath, item.target);
  results.push({ name: item.name, state: "ok", detail: "replaced" });
}

async function applyTextOp(item, version, results) {
  if (!existsSync(item.target)) {
    results.push({ name: item.name, state: "skipped", detail: "target missing (layout changed?)" });
    return;
  }
  const original = await readFile(item.target, "utf8");
  if (original.includes(item.marker)) {
    results.push({ name: item.name, state: "ok", detail: "already applied" });
    return;
  }
  let text = original;
  const applied = [];
  for (const op of item.ops) {
    if (!text.includes(op.find)) continue;
    text = text.split(op.find).join(op.replace);
    applied.push(op.label);
  }
  if (!applied.length) {
    results.push({ name: item.name, state: "skipped", detail: "no pattern matched (upstream changed?)" });
    return;
  }
  await backupOnce(item.target, version);
  await writeFile(item.target, text, "utf8");
  results.push({ name: item.name, state: "ok", detail: `patched: ${applied.join("; ")}` });
}

/** Skip a JS string/template literal starting at `i`; returns the closing index. */
function endOfString(text, i) {
  const quote = text[i];
  i++;
  while (i < text.length && text[i] !== quote) {
    if (text[i] === "\\") i++;
    i++;
  }
  return i;
}

/**
 * Bounds of a minified function definition starting at `from`.
 *
 * Returns { paramsEnd, end }: `paramsEnd` is just past the closing paren of the
 * parameter list (so a destructuring default like `{size:t=24}` can be read from
 * the signature), and `end` is just past the closing brace of the body. Scanning
 * has to skip the parameter list first — starting the brace counter at the first
 * `{` would stop at `{size:t=24,className:r}` and miss the body entirely.
 */
function boundsOfFunction(text, from) {
  const parenOpen = text.indexOf("(", from);
  if (parenOpen < 0) return null;
  let depth = 0;
  let i = parenOpen;
  for (; i < text.length; i++) {
    const ch = text[i];
    if (ch === '"' || ch === "'" || ch === "`") {
      i = endOfString(text, i);
      continue;
    }
    if (ch === "(") depth++;
    else if (ch === ")" && --depth === 0) break;
  }
  const paramsEnd = i + 1;
  const bodyOpen = text.indexOf("{", paramsEnd);
  if (bodyOpen < 0) return null;
  depth = 0;
  for (i = bodyOpen; i < text.length; i++) {
    const ch = text[i];
    if (ch === '"' || ch === "'" || ch === "`") {
      i = endOfString(text, i);
      continue;
    }
    if (ch === "{") depth++;
    else if (ch === "}" && --depth === 0) return { paramsEnd, end: i + 1 };
  }
  return null;
}

/**
 * Rewrite the FishLogo component and the BrandWordmark whale in a minified
 * bundle. Unlike the Windows port this does not hardcode minifier output
 * (`function md(`); it discovers the aliases from the export map and from the
 * component itself, so a new upstream build with different mangled names still
 * patches. A failed `node --check` restores the backup.
 */
async function applyBundleOp(item, version, results) {
  const knot = item.knot;
  if (!existsSync(item.dir)) {
    results.push({ name: item.name, state: "skipped", detail: "assets dir missing" });
    return;
  }
  const files = (await safeReaddir(item.dir)).filter((f) => item.pattern.test(f));
  if (!files.length) {
    results.push({ name: item.name, state: "skipped", detail: "no index-*.js bundle found" });
    return;
  }
  for (const file of files) {
    const text = await readFile(join(item.dir, file), "utf8");
    if (text.includes(knot.path)) {
      results.push({ name: item.name, state: "ok", detail: `${file}: already applied` });
      return;
    }
  }

  for (const file of files) {
    const target = join(item.dir, file);
    const original = await readFile(target, "utf8");
    const applied = [];

    // --- FishLogo: locate the exported alias, then bound its definition ---
    const exported = /FishLogo:(\w+)/.exec(original);
    if (!exported) {
      results.push({ name: item.name, state: "skipped", detail: `${file}: "FishLogo:" export not found` });
      continue;
    }
    const alias = exported[1];
    const fnStart = original.indexOf(`function ${alias}(`);
    if (fnStart < 0) {
      results.push({ name: item.name, state: "skipped", detail: `${file}: FishLogo alias ${alias} has no function definition` });
      continue;
    }
    const bounds = boundsOfFunction(original, fnStart);
    if (!bounds) {
      results.push({ name: item.name, state: "skipped", detail: `${file}: cannot bound FishLogo function` });
      continue;
    }
    const fnEnd = bounds.end;
    let slice = original.slice(fnStart, fnEnd);
    const signature = original.slice(fnStart, bounds.paramsEnd);
    const sizeVar = (/size:\s*(\w+)\s*=/.exec(signature) || [])[1];
    const pathRef = /\bd:\s*(\w+)\s*,\s*fill:\s*"currentColor"/.exec(slice);
    if (!sizeVar || !pathRef) {
      results.push({ name: item.name, state: "skipped", detail: `${file}: FishLogo shape not recognised` });
      continue;
    }
    const before = slice;
    slice = slice
      // square artwork: drop the old 23.16 x 17.04 aspect correction
      .replace(/height:\s*[^,}]*\.height\s*\/\s*[^,}]*\.width/, `height:${sizeVar}`)
      .replace(/viewBox:\s*`[^`]*`/, 'viewBox:"0 0 24 24"')
      .replace(/viewBox:\s*"0 0 [\d.]+ [\d.]+"/, 'viewBox:"0 0 24 24"')
      .replace(pathRef[0], `d:"${knot.path}",fill:"${knot.fill}"`);
    if (slice === before) {
      results.push({ name: item.name, state: "skipped", detail: `${file}: FishLogo replacements did not apply` });
      continue;
    }
    applied.push("FishLogo");

    let text = original.slice(0, fnStart) + slice + original.slice(fnEnd);

    // --- BrandWordmark: replace the clipped whale group with the knot ---
    const whaleRe =
      /(\w+)\.jsx\("g",\{clipPath:"url\(#dsh-wordmark-whale-clip\)",children:\1\.jsx\("path",\{d:"[^"]+",fill:"currentColor"\}\)\}\)/;
    const whale = whaleRe.exec(text);
    if (whale) {
      // The whale occupied 23.16 x 17.04 at (0.141602, 3.52185); scale the 24x24
      // knot into that same box so the wordmark keeps its original metrics.
      text = text.replace(
        whaleRe,
        `${whale[1]}.jsx("path",{d:"${knot.path}",fill:"${knot.fill}",transform:"translate(0.141602 3.52185) scale(0.965 0.71)"})`
      );
      applied.push("wordmark whale");
    }

    const backup = await backupOnce(target, version);
    await writeFile(target, text, "utf8");
    const check = spawnSync(process.execPath, ["--check", target], { timeout: 30000 });
    if (check.status !== 0) {
      if (backup) await copyFile(backup, target);
      results.push({
        name: item.name,
        state: "error",
        detail: `${file}: syntax check failed, restored backup: ${String(check.stderr).slice(0, 200)}`
      });
      return;
    }
    results.push({ name: item.name, state: "ok", detail: `${file}: patched ${applied.join(" + ")}` });
    return; // only the primary index bundle carries the React UI
  }
}

// ------------------------------------------------------------------ plan

function buildPlan(root, knot) {
  const plan = [
    {
      kind: "file",
      name: "web favicon (blue hollow knot)",
      target: join(root.dist, "favicon.svg"),
      asset: "knot.svg"
    },
    {
      kind: "bundle",
      name: "FishLogo + BrandWordmark (web bundle)",
      dir: join(root.dist, "assets"),
      pattern: /^index-.+\.js$/,
      knot
    }
  ];

  const badge = join(root.nodeModules, "@deepseek-ai", "dsh-skill-badge", "assets");
  if (existsSync(badge)) {
    plan.push({
      kind: "file",
      name: "skill badge image",
      target: join(badge, "dsh-badge.png"),
      asset: "dsh-badge.png"
    });
    plan.push({
      kind: "text",
      name: "skill badge shields.io logo",
      target: join(badge, "dsh-badge.md"),
      marker: "logoColor=1E6FEB",
      ops: [
        {
          label: "badge logo=deepseek -> logo=openai",
          find: "logo=deepseek&logoColor=white",
          replace: "logo=openai&logoColor=1E6FEB"
        }
      ]
    });
  }

  return plan;
}

// ------------------------------------------------------------------ repair

let repairRunning = false;
let lastResult = null;

async function repairRoot(root, knot, allResults) {
  const version = await frontendVersion(root.dist);
  const results = [];
  for (const item of buildPlan(root, knot)) {
    try {
      if (item.kind === "file") await applyFileOp(item, version, results);
      else if (item.kind === "text") await applyTextOp(item, version, results);
      else if (item.kind === "bundle") await applyBundleOp(item, version, results);
    } catch (error) {
      results.push({ name: item.name, state: "error", detail: error.message });
    }
  }
  allResults.push({ dist: root.dist, source: root.source, version, items: results });
}

async function repairNow() {
  if (repairRunning) return lastResult ?? { items: [{ name: "repair", state: "busy" }] };
  repairRunning = true;
  try {
    const knot = await readKnot();
    const roots = await findFrontendDists();
    const all = [];
    if (!roots.length) {
      all.push({
        dist: null,
        source: null,
        version: null,
        items: [
          {
            name: "frontend discovery",
            state: "error",
            detail:
              "no @deepseek-ai/dsh-web-frontend/dist found — is this a dsh-web profile? " +
              "set DSH_UBUNTU_ICON_ROOT to the package dir or its dist/ to pin one"
          }
        ]
      });
    }
    for (const root of roots) {
      try {
        await repairRoot(root, knot, all);
      } catch (error) {
        all.push({ dist: root.dist, source: root.source, items: [{ name: "repair", state: "error", detail: error.message }] });
      }
    }
    const summary = { at: new Date().toISOString(), roots: roots.length, targets: all };
    lastResult = summary;
    for (const t of all) {
      for (const item of t.items) {
        await log(`${String(item.state).toUpperCase().padEnd(7)} ${t.dist ?? "-"} :: ${item.name}: ${item.detail}`);
      }
    }
    return summary;
  } finally {
    repairRunning = false;
  }
}

// ------------------------------------------------------------- plugin entry

function sendJson(res, status, body) {
  res.writeHead(status, { "content-type": "application/json" });
  res.end(JSON.stringify(body, null, 2));
}

function apply(ctx) {
  let server = null;
  try {
    server = ctx.get("webServer") ?? null;
  } catch {
    /* service unavailable */
  }
  ctx.effect(() => {
    const offs = [];
    if (server) {
      offs.push(
        server.register({
          kind: "exact",
          path: ROUTE_STATUS,
          handler: (req, res) => sendJson(res, 200, { ok: true, name, lastResult })
        })
      );
      offs.push(
        server.register({
          kind: "exact",
          path: ROUTE_REPAIR,
          handler: async (req, res) => sendJson(res, 200, await repairNow())
        })
      );
    } else {
      log("webServer service unavailable; HTTP routes disabled");
    }
    // Repair shortly after boot: the harness is not slowed down, and a frontend
    // that an npm update just replaced is re-branded without user action.
    const timer = setTimeout(() => {
      repairNow().catch((error) => log(`repair failed: ${error && error.stack ? error.stack : error}`));
    }, 3000);
    return () => {
      clearTimeout(timer);
      for (const off of offs) off();
    };
  }, `${name}: repair + routes`);
}

export { apply, inject, name };
