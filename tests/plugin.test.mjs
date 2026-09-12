/**
 * Offline test for the dsh-ubutu-icon host half.
 *
 * It loads `lib/index.js` exactly the way the harness does — `apply(ctx)` with a
 * fake `webServer` — and then drives the real `/ubuntu-icon/repair` handler
 * against a throwaway copy of a frontend dist. Nothing outside the temp dir is
 * touched, and the live DSH installation is never patched.
 *
 * Run: node tests/plugin.test.mjs
 */
import { existsSync } from "node:fs";
import { cp, mkdtemp, mkdir, readFile, readdir, rm, writeFile } from "node:fs/promises";
import { createHash } from "node:crypto";
import { spawnSync } from "node:child_process";
import { homedir, tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = dirname(dirname(fileURLToPath(import.meta.url)));
const sha256 = (b) => createHash("sha256").update(b).digest("hex");

let pass = 0;
let fail = 0;
const ok = (m) => {
  console.log(`  [PASS] ${m}`);
  pass++;
};
const bad = (m) => {
  console.log(`  [FAIL] ${m}`);
  fail++;
};

/** A minified bundle shaped like the real vite output (mangled names included). */
const SYNTHETIC_BUNDLE = `const __vite__mapDeps=(i,m=__vite__mapDeps,d=(m.f||(m.f=[])))=>i.map(i=>d[i]);
function a(){}
const Ir={width:23.16,height:17.04},B4="M22.9168 1.43018C22.6713 1.31018 22.5658 1.53918Z";
function uC({size:t=24,className:r}){return a.jsx("svg",{width:t,height:t*Ir.height/Ir.width,className:r,viewBox:\`0 0 \${Ir.width} \${Ir.height}\`,fill:"none","aria-hidden":"true",children:a.jsx("path",{d:B4,fill:"currentColor"})})}
function fC({size:t=24,className:r,includeMark:i=!0}){return a.jsxs("svg",{width:t*(i?182:156)/24,height:t,className:r,viewBox:i?"0 0 182 24":"26 0 156 24",fill:"none","aria-hidden":"true",children:[a.jsx("path",{d:"M68.416 18.2447H71Z",fill:"currentColor"}),a.jsx("g",{clipPath:"url(#dsh-wordmark-whale-clip)",children:a.jsx("path",{d:"M23.0584 4.95203C22.8129 4.83203Z",fill:"currentColor"})}),a.jsxs("defs",{children:[a.jsx("clipPath",{id:"dsh-wordmark-whale-clip",children:a.jsx("rect",{width:"23.16",height:"17.0435",fill:"white",transform:"translate(0.141602 3.52185)"})})]})]})}
export{FishLogo:uC,BrandWordmark:fC,FISH_LOGO_PATH:B4,FISH_LOGO_VIEWBOX:Ir};`;

/** Prefer a real installed frontend (best fidelity), else the synthetic fixture. */
async function findRealDist() {
  if (process.env.DSH_UBUNTU_ICON_TEST_DIST) return process.env.DSH_UBUNTU_ICON_TEST_DIST;
  if (process.env.DSH_UBUNTU_ICON_TEST_SYNTHETIC) return null;
  const roots = [join(homedir(), ".npm", "_npx"), "/usr/lib/node_modules", "/usr/local/lib/node_modules"];
  for (const root of roots) {
    let entries = [];
    try {
      entries = await readdir(root);
    } catch {
      continue;
    }
    for (const entry of entries) {
      const dist = join(root, entry, "node_modules", "@deepseek-ai", "dsh-web-frontend", "dist");
      if (existsSync(join(dist, "favicon.svg"))) return dist;
    }
  }
  return null;
}

/**
 * Is this frontend still stock? Once the plugin has run on this machine the live
 * files are already blue knots, and repairing those is correctly a no-op — no
 * backups, nothing to assert. Reusing such a dist would make the suite depend on
 * whether the plugin happens to be installed, so it is rejected in favour of the
 * synthetic fixture (which is stock by construction, hence deterministic).
 */
async function isPristine(dist, assets) {
  try {
    const favicon = await readFile(join(dist, "favicon.svg"), "utf8");
    if (favicon.includes(KNOT_MARKER)) return false;
    for (const file of assets.filter((f) => /^index-.+\.js$/.test(f))) {
      if ((await readFile(join(dist, "assets", file), "utf8")).includes(KNOT_PATH_HEAD)) return false;
    }
    return true;
  } catch {
    return false;
  }
}

/** Signatures the patch itself leaves behind — i.e. "this file is already branded". */
const KNOT_MARKER = "#1E6FEB";
const KNOT_PATH_HEAD = "M22.2819 9.8211";

const tmp = await mkdtemp(join(tmpdir(), "ubutu-icon-test-"));
const home = join(tmp, "home");
const pkgDir = join(tmp, "node_modules", "@deepseek-ai", "dsh-web-frontend");
const dist = join(pkgDir, "dist");
await mkdir(join(dist, "assets"), { recursive: true });
await mkdir(home, { recursive: true });

const candidate = await findRealDist();
const realAssets = candidate ? await readdir(join(candidate, "assets")) : [];
const real = candidate && (await isPristine(candidate, realAssets)) ? candidate : null;
if (candidate && !real) {
  console.log(`== fixture: ${candidate} is already branded (the plugin has run here) -> using the synthetic fixture`);
}
let bundleName = "index-TEST0000.js";
if (real) {
  const indexJs = realAssets.filter((f) => /^index-.+\.js$/.test(f));
  await cp(join(real, "favicon.svg"), join(dist, "favicon.svg"));
  if (existsSync(join(real, "index.html"))) await cp(join(real, "index.html"), join(dist, "index.html"));
  if (indexJs.length) {
    bundleName = indexJs[0];
    await cp(join(real, "assets", bundleName), join(dist, "assets", bundleName));
  }
  console.log(`== fixture: real frontend from ${real} (${bundleName})`);
} else {
  await writeFile(join(dist, "favicon.svg"), '<svg xmlns="http://www.w3.org/2000/svg"><path d="M0 0h10v10H0z" fill="#111"/></svg>\n');
  await writeFile(join(dist, "index.html"), "<!doctype html><title>DeepSeek Harness</title>\n");
  await writeFile(join(dist, "assets", bundleName), SYNTHETIC_BUNDLE);
  console.log("== fixture: synthetic bundle (hermetic, stock by construction)");
}
await writeFile(join(pkgDir, "package.json"), JSON.stringify({ name: "@deepseek-ai/dsh-web-frontend", version: "9.9.9-test" }, null, 2));

const bundlePath = join(dist, "assets", bundleName);
const faviconPath = join(dist, "favicon.svg");
const faviconBefore = sha256(await readFile(faviconPath));
const bundleBefore = sha256(await readFile(bundlePath));

// The suite asserts that the first repair CREATES backups, which only holds from
// a stock starting point. Fail loudly here rather than three assertions later.
const fixtureBundleText = await readFile(bundlePath, "utf8");
if (fixtureBundleText.includes(KNOT_PATH_HEAD) || (await readFile(faviconPath, "utf8")).includes(KNOT_MARKER)) {
  console.log("  [FAIL] fixture is already branded; refusing to run (see isPristine)");
  process.exit(1);
}

process.env.DSH_HOME = home;
process.env.DSH_UBUNTU_ICON_ROOT = pkgDir;

console.log("== load the plugin the way the harness does");
const plugin = await import(join(repoRoot, "lib", "index.js"));
const handlers = new Map();
let disposed = false;
const fakeCtx = {
  get: (svc) =>
    svc === "webServer"
      ? {
          register: ({ path, handler }) => {
            handlers.set(path, handler);
            return () => handlers.delete(path);
          }
        }
      : null,
  effect: (fn) => {
    const dispose = fn();
    return () => {
      disposed = true;
      if (typeof dispose === "function") dispose();
    };
  }
};
plugin.name === "dsh-ubutu-icon" ? ok(`plugin name = ${plugin.name}`) : bad(`unexpected name ${plugin.name}`);
Array.isArray(plugin.inject) && plugin.inject.includes("webServer")
  ? ok("injects webServer")
  : bad("webServer not injected");
typeof plugin.apply === "function" ? ok("exports apply()") : bad("apply() missing");
const dispose = fakeCtx.effect === undefined ? null : null;

console.log("== apply(ctx) registers routes and starts the boot repair");
// apply() installs its own effect; call it directly.
plugin.apply(fakeCtx);
handlers.has("/ubuntu-icon/status") ? ok("route /ubuntu-icon/status") : bad("status route missing");
handlers.has("/ubuntu-icon/repair") ? ok("route /ubuntu-icon/repair") : bad("repair route missing");

const callRoute = async (path) => {
  let body = "";
  const res = {
    status: 0,
    writeHead(s) {
      this.status = s;
    },
    end(b) {
      body = b;
    }
  };
  await handlers.get(path)({ method: "GET" }, res);
  return { status: res.status, body: JSON.parse(body) };
};

console.log("== first repair (fresh, unpatched frontend)");
const first = await callRoute("/ubuntu-icon/repair");
const items = first.body.targets.flatMap((t) => t.items);
const state = (n) => (items.find((i) => i.name.includes(n)) || {}).state;
first.body.roots >= 1 ? ok(`discovered ${first.body.roots} frontend dist(s)`) : bad("no frontend discovered");
state("favicon") === "ok" ? ok("favicon replaced") : bad(`favicon state = ${state("favicon")}`);
state("FishLogo") === "ok" ? ok("bundle patched") : bad(`bundle state = ${state("FishLogo")} (${JSON.stringify(items)})`);

const faviconAfter = await readFile(faviconPath);
const knot = await readFile(join(repoRoot, "assets", "knot.svg"));
sha256(faviconAfter) === sha256(knot)
  ? ok("favicon bytes == assets/knot.svg")
  : bad("favicon bytes differ from the shipped artwork");

const patched = await readFile(bundlePath, "utf8");
const knotPath = /<path[^>]*\sd="([^"]+)"/.exec(knot.toString("utf8"))[1];
patched.includes(knotPath) ? ok("knot path injected into the bundle") : bad("knot path missing from bundle");
patched.includes('viewBox:"0 0 24 24"') ? ok("FishLogo viewBox squared to 24x24") : bad("viewBox not squared");
patched.includes("dsh-wordmark-whale-clip") && !/jsx\("g",\{clipPath:"url\(#dsh-wordmark-whale-clip\)",children:/.test(patched)
  ? ok("wordmark whale group replaced by knot")
  : bad("wordmark whale still in place");
const syntactic = spawnSync(process.execPath, ["--check", bundlePath], { timeout: 30000 });
syntactic.status === 0
  ? ok("patched bundle passes node --check")
  : bad(`patched bundle syntax error: ${String(syntactic.stderr).slice(0, 200)}`);

const backupDir = join(home, "ubuntu-icon-data", "backup", "9.9.9-test");
const backups = existsSync(backupDir) ? await readdir(backupDir) : [];
backups.length >= 2 ? ok(`backups written (${backups.length} files)`) : bad(`expected backups, found ${backups.length}`);
const backupHash = backups.find((b) => b.endsWith(bundleName));
if (backupHash) {
  sha256(await readFile(join(backupDir, backupHash))) === bundleBefore
    ? ok("backup holds the pristine bundle")
    : bad("backup does not match the pristine bundle");
} else {
  bad("no bundle backup found");
}

const manifestPath = join(backupDir, "manifest.json");
if (existsSync(manifestPath)) {
  const manifest = JSON.parse(await readFile(manifestPath, "utf8"));
  const entry = Object.values(manifest).find((e) => e.target === bundlePath);
  entry && entry.sha256 === bundleBefore
    ? ok("manifest records the original path + hash (drives tools/restore.sh)")
    : bad(`manifest entry wrong: ${JSON.stringify(entry)}`);
} else {
  bad("manifest.json missing");
}

console.log("== second repair must be a no-op");
const second = await callRoute("/ubuntu-icon/repair");
const items2 = second.body.targets.flatMap((t) => t.items);
const allIdempotent = items2.every((i) => i.state === "ok" && /already applied/.test(i.detail));
allIdempotent ? ok("every target reports 'already applied'") : bad(`not idempotent: ${JSON.stringify(items2)}`);
sha256(await readFile(bundlePath)) === sha256(Buffer.from(patched))
  ? ok("bundle byte-identical after the second run")
  : bad("second run modified the bundle");

console.log("== status route");
const status = await callRoute("/ubuntu-icon/status");
status.status === 200 && status.body.ok === true && status.body.lastResult
  ? ok("status route reports the last repair")
  : bad(`status route returned ${JSON.stringify(status).slice(0, 160)}`);

console.log("== backups restore the original files");
for (const file of backups) {
  const original = file.endsWith(bundleName) ? bundleBefore : faviconBefore;
  const restored = sha256(await readFile(join(backupDir, file)));
  if (file.endsWith(bundleName) || file.endsWith("favicon.svg")) {
    restored === original ? ok(`restore ${file.slice(0, 40)}`) : bad(`restore mismatch for ${file}`);
  }
}

console.log("== log file");
const logPath = join(home, "ubuntu-icon-data", "ubuntu-icon.log");
existsSync(logPath) && (await readFile(logPath, "utf8")).includes("OK")
  ? ok("repair log written")
  : bad("repair log missing");

await rm(tmp, { recursive: true, force: true });
console.log(`\n== plugin.test.mjs: ${pass} passed, ${fail} failed ==`);
process.exit(fail === 0 ? 0 : 1);
