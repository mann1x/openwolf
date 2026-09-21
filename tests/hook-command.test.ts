import { test, describe } from "node:test";
import * as assert from "node:assert";

import { buildHookCommand, ensureHookLauncher } from "../dist/src/utils/hook-command.js";
import { buildHookSettings } from "../dist/src/cli/hook-manifest.js";

// The Windows console flash on every tool call comes from console ALLOCATION:
// node.exe is a console-subsystem binary, so a parent with no console of its
// own forces Windows to allocate one, and it is visible. Measured 2026-09-21 on
// Windows 10 Pro (interactive) and GitHub windows-latest — see
// scripts/study-gui-launcher.ps1, which also measures the fix.
//
// The earlier attempt (wscript + WScript.Shell.Run, SW_HIDE) hid the window but
// replaced the child's pipes with a fresh console, and Claude Code delivers the
// hook payload on stdin and reads the reply on stdout — so every wrapped hook
// hung until its timeout. These tests therefore pin the two properties that
// matter for correctness rather than the wrapping itself:
//
//   1. POSIX is untouched, byte for byte.
//   2. A missing launcher degrades to the plain node form, never to something
//      that cannot run. A flashing hook beats a dead one.

const LAUNCHER = "C:/Users/x/AppData/Roaming/npm/node_modules/openwolf/dist/assets/hook-launcher.exe";
const SCRIPT = "C:/proj/.wolf/hooks/post-write.js";

describe("buildHookCommand", () => {
  test("POSIX is the bare form, launcher present or not", () => {
    for (const platform of ["linux", "darwin"] as const) {
      assert.strictEqual(
        buildHookCommand("/proj/.wolf/hooks/post-write.js", { platform, launcher: LAUNCHER }),
        'node "/proj/.wolf/hooks/post-write.js"'
      );
    }
  });

  test("win32 with a launcher routes through it", () => {
    assert.strictEqual(
      buildHookCommand(SCRIPT, { platform: "win32", launcher: LAUNCHER }),
      `"${LAUNCHER}" node "${SCRIPT}"`
    );
  });

  test("win32 without a launcher is the historical form", () => {
    // The whole fallback story: a blocked compiler, a locked-down box or a
    // partial install must leave a working hook behind.
    assert.strictEqual(
      buildHookCommand(SCRIPT, { platform: "win32", launcher: null }),
      `node "${SCRIPT}"`
    );
  });

  test("backslashes in the launcher path are normalised", () => {
    // The command is written into settings.json, where a backslash needs
    // escaping; forward slashes round-trip and Windows accepts them.
    const cmd = buildHookCommand(SCRIPT, {
      platform: "win32",
      launcher: "C:\\tools\\openwolf\\dist\\assets\\hook-launcher.exe",
    });
    assert.ok(!cmd.includes("\\"), `command still contains a backslash: ${cmd}`);
    assert.ok(cmd.startsWith('"C:/tools/openwolf/dist/assets/hook-launcher.exe" node '));
  });

  test("the script path is passed through untouched", () => {
    // hook-manifest.ts owns path syntax, including the absolute-path decision
    // and its history; this function must not second-guess it.
    const odd = "C:/a b/proj/.wolf/hooks/pre-bash.js";
    assert.ok(buildHookCommand(odd, { platform: "win32", launcher: LAUNCHER }).endsWith(`node "${odd}"`));
    assert.ok(buildHookCommand(odd, { platform: "win32", launcher: null }).endsWith(`node "${odd}"`));
  });
});

describe("ensureHookLauncher", () => {
  test("is a no-op off Windows", () => {
    // Called unconditionally by init and update; on POSIX it must not look for
    // a compiler, or report anything.
    const logged: string[] = [];
    assert.strictEqual(ensureHookLauncher({ platform: "linux", log: (m) => logged.push(m) }), null);
    assert.deepStrictEqual(logged, []);
  });
});

describe("buildHookSettings", () => {
  test("every registered hook command still runs the right script", () => {
    // Guards the wiring rather than the wrapper: whatever the command is
    // wrapped in, all 12 entries must still point at their own script under
    // the project's absolute .wolf/hooks path.
    const settings = buildHookSettings("/home/u/proj");
    const commands: string[] = [];
    for (const matchers of Object.values(settings.hooks)) {
      for (const m of matchers as Array<{ hooks: Array<{ command: string }> }>) {
        for (const h of m.hooks) commands.push(h.command);
      }
    }
    assert.ok(commands.length >= 12, `expected the full manifest, got ${commands.length}`);
    for (const c of commands) {
      assert.match(c, /^node "\/home\/u\/proj\/\.wolf\/hooks\/[a-z-]+\.js"$/);
    }
    assert.strictEqual(new Set(commands).size, commands.length, "a script is registered twice");
  });

  test("a trailing slash or backslash in the project path does not double up", () => {
    for (const root of ["/home/u/proj/", "/home/u/proj//"]) {
      for (const matchers of Object.values(buildHookSettings(root).hooks)) {
        for (const m of matchers as Array<{ hooks: Array<{ command: string }> }>) {
          for (const h of m.hooks) assert.ok(!h.command.includes("//.wolf"), h.command);
        }
      }
    }
  });
});
