import * as fs from "node:fs";
import * as path from "node:path";
import { fileURLToPath } from "node:url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

/**
 * Locate the bundled hook-runner.vbs (shipped under dist/assets/).
 *
 * At runtime this module lives at dist/src/utils/hook-command.js and the
 * VBS is copied to dist/assets/hook-runner.vbs by the build; in source
 * mode it is at <repo>/assets/hook-runner.vbs.
 *
 * Returns null when no candidate exists, and the caller then emits the
 * historical bare `node "<script>"` form unchanged.
 */
export function findHookRunnerVbs(): string | null {
  const candidates = [
    path.resolve(__dirname, "..", "..", "assets", "hook-runner.vbs"),
    path.resolve(__dirname, "..", "..", "..", "assets", "hook-runner.vbs"),
    path.resolve(__dirname, "assets", "hook-runner.vbs"),
  ];
  for (const c of candidates) {
    if (fs.existsSync(c)) return c;
  }
  return null;
}

/**
 * Build the settings.json `command` string that runs one hook script.
 *
 * `scriptPath` is the absolute, forward-slashed path the caller has
 * already composed, so this function never invents path syntax — see the
 * note in hook-manifest.ts for why the absolute form is load-bearing.
 *
 * On Windows, when the VBS asset is present, the command becomes
 *   wscript //nologo "<vbs>" node "<script>"
 * because wscript.exe is a windows-subsystem host and the VBS runs the
 * child with SW_HIDE, so no console window is shown.
 *
 * IMPORTANT — this wrapper is only safe for a hook that needs neither
 * stdin nor stdout. `WScript.Shell.Run` gives the child a fresh hidden
 * console instead of the parent's pipes, so anything the hook reads from
 * stdin or writes to stdout is lost. Claude Code delivers the event
 * payload on stdin and reads the hook's response from stdout, so callers
 * must pass `requiresStdio: true` for those. scripts/validate-console-flash.ps1
 * is the check that keeps this honest.
 */
export function buildHookCommand(
  scriptPath: string,
  opts: {
    platform?: NodeJS.Platform;
    vbsPath?: string | null;
    requiresStdio?: boolean;
  } = {}
): string {
  const platform = opts.platform ?? process.platform;
  const vbsPath = opts.vbsPath === undefined ? findHookRunnerVbs() : opts.vbsPath;
  const bare = `node "${scriptPath}"`;
  if (platform !== "win32" || !vbsPath) return bare;
  if (opts.requiresStdio !== false) return bare;
  return `wscript //nologo "${vbsPath.replace(/\\/g, "/")}" node "${scriptPath}"`;
}
