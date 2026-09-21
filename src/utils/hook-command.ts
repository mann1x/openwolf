import { spawnSync } from "node:child_process";
import * as fs from "node:fs";
import * as path from "node:path";
import { fileURLToPath } from "node:url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

/** dist/assets at runtime, <repo>/assets in dev — first one that exists. */
function assetDirs(): string[] {
  return [
    path.resolve(__dirname, "..", "..", "assets"),        // dist/src/utils -> dist/assets
    path.resolve(__dirname, "..", "..", "..", "assets"),  // src/utils -> <repo>/assets
    path.resolve(__dirname, "assets"),
  ];
}

const LAUNCHER_EXE = "hook-launcher.exe";
const LAUNCHER_SRC = "hook-launcher.cs";

/** An already-built launcher, or null. */
export function findHookLauncher(): string | null {
  for (const dir of assetDirs()) {
    const exe = path.join(dir, LAUNCHER_EXE);
    if (fs.existsSync(exe)) return exe;
  }
  return null;
}

/** The csc.exe that ships with the .NET Framework, newest first. */
function findCsc(): string | null {
  const roots = [
    "C:\\Windows\\Microsoft.NET\\Framework64",
    "C:\\Windows\\Microsoft.NET\\Framework",
  ];
  for (const root of roots) {
    let versions: string[];
    try {
      versions = fs.readdirSync(root).filter((v) => v.startsWith("v")).sort().reverse();
    } catch {
      continue;
    }
    for (const v of versions) {
      const csc = path.join(root, v, "csc.exe");
      if (fs.existsSync(csc)) return csc;
    }
  }
  return null;
}

/**
 * Build the hook launcher if it is missing, and return its path.
 *
 * Compiled on demand rather than published, so no binary is committed or
 * shipped in the tarball: the C# source travels instead, and the csc.exe that
 * ships with the .NET Framework on every Windows does the build. init and
 * update call this before writing hook commands.
 *
 * Returns null for every failure — wrong platform, no compiler, unwritable
 * asset directory, a compile error — because the caller's fallback is the
 * historical `node "<script>"` form, which works and merely flashes. A hook
 * that does not run is far worse than a hook that blinks.
 */
export function ensureHookLauncher(
  opts: { platform?: NodeJS.Platform; log?: (msg: string) => void } = {}
): string | null {
  const platform = opts.platform ?? process.platform;
  if (platform !== "win32") return null;

  const existing = findHookLauncher();
  if (existing) {
    // Rebuild when the shipped source is newer than the binary, so an
    // upgrade does not keep running last version's launcher.
    const src = assetDirs()
      .map((d) => path.join(d, LAUNCHER_SRC))
      .find((p) => fs.existsSync(p));
    try {
      if (!src || fs.statSync(src).mtimeMs <= fs.statSync(existing).mtimeMs) return existing;
    } catch {
      return existing;
    }
  }

  const src = assetDirs()
    .map((d) => path.join(d, LAUNCHER_SRC))
    .find((p) => fs.existsSync(p));
  if (!src) {
    opts.log?.("openwolf: hook-launcher.cs not found; hooks will use the plain node form");
    return null;
  }
  const csc = findCsc();
  if (!csc) {
    opts.log?.("openwolf: no .NET Framework csc.exe found; hooks will use the plain node form");
    return null;
  }
  const exe = path.join(path.dirname(src), LAUNCHER_EXE);
  const res = spawnSync(csc, ["/nologo", "/target:winexe", "/optimize+", `/out:${exe}`, src], {
    encoding: "utf8",
    timeout: 60_000,
    windowsHide: true,
  });
  if (res.error || res.status !== 0 || !fs.existsSync(exe)) {
    const why = res.error?.message ?? `${res.stdout ?? ""}${res.stderr ?? ""}`.trim() ?? "unknown";
    opts.log?.(`openwolf: could not build the hook launcher (${why}); hooks will use the plain node form`);
    return null;
  }
  opts.log?.(`openwolf: built the hook launcher at ${exe}`);
  return exe;
}

/**
 * Build the settings.json `command` string that runs one hook script.
 *
 * `scriptPath` is the absolute, forward-slashed path the caller composed —
 * see hook-manifest.ts for why absolute is load-bearing. This function never
 * invents path syntax.
 *
 * On Windows, with a launcher available, the command becomes
 *   "<launcher>" node "<script>"
 * which runs the hook with no console window while leaving stdin, stdout and
 * the exit code intact. Everywhere else, and whenever the launcher is
 * missing, it is the historical `node "<script>"`.
 */
export function buildHookCommand(
  scriptPath: string,
  opts: { platform?: NodeJS.Platform; launcher?: string | null } = {}
): string {
  const platform = opts.platform ?? process.platform;
  const bare = `node "${scriptPath}"`;
  if (platform !== "win32") return bare;
  const launcher = opts.launcher === undefined ? findHookLauncher() : opts.launcher;
  if (!launcher) return bare;
  return `"${launcher.replace(/\\/g, "/")}" node "${scriptPath}"`;
}
