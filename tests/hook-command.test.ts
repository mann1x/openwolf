import { test, describe } from "node:test";
import * as assert from "node:assert";

import { buildHookCommand } from "../dist/src/utils/hook-command.js";

// PR #42 (mann1x, with @Mizuho0329): on Windows, Claude Code spawning
// `node "<hook>.js"` flashes a console window on every tool call, because
// node.exe is a console-subsystem binary. The proposed fix routes the call
// through wscript.exe — a windows-subsystem host — running the child with
// SW_HIDE via assets/hook-runner.vbs.
//
// The wrapper is NOT a free win, and that is what these tests pin. It is
// built on WScript.Shell.Run, which hands the child a fresh hidden console
// instead of the parent's pipes. Claude Code delivers the hook payload on
// stdin and reads the response from stdout (see the note at the top of
// hook-manifest.ts), so wrapping a hook that needs either one hides a
// window by silently breaking the hook. The default therefore refuses to
// wrap, and a caller has to say `requiresStdio: false` to opt in.
//
// scripts/validate-console-flash.ps1 is the other half: it proves on a real
// Windows runner both that the flash exists and what the wrapper does to
// the round-trip. Unit tests can only pin the decision, not the behaviour.

const VBS = "C:/tools/openwolf/dist/assets/hook-runner.vbs";
const SCRIPT = "C:/proj/.wolf/hooks/post-write.js";

describe("buildHookCommand", () => {
  test("POSIX is the bare form, wrapper present or not", () => {
    assert.strictEqual(
      buildHookCommand("/proj/.wolf/hooks/post-write.js", { platform: "linux", vbsPath: VBS }),
      'node "/proj/.wolf/hooks/post-write.js"'
    );
    assert.strictEqual(
      buildHookCommand("/proj/.wolf/hooks/post-write.js", { platform: "darwin", vbsPath: VBS }),
      'node "/proj/.wolf/hooks/post-write.js"'
    );
  });

  test("a stdio-using hook is never wrapped, and that is the default", () => {
    // The regression that matters: every Claude Code hook reads stdin, so a
    // default of "wrap" would break all of them to remove a flash.
    assert.strictEqual(
      buildHookCommand(SCRIPT, { platform: "win32", vbsPath: VBS }),
      `node "${SCRIPT}"`
    );
    assert.strictEqual(
      buildHookCommand(SCRIPT, { platform: "win32", vbsPath: VBS, requiresStdio: true }),
      `node "${SCRIPT}"`
    );
  });

  test("opting out of stdio on win32 wraps through wscript", () => {
    assert.strictEqual(
      buildHookCommand(SCRIPT, { platform: "win32", vbsPath: VBS, requiresStdio: false }),
      `wscript //nologo "${VBS}" node "${SCRIPT}"`
    );
  });

  test("a missing VBS asset falls back to the bare form", () => {
    // The asset is copied by the build; a partial install must degrade to
    // the historical behaviour rather than emit a command to nothing.
    assert.strictEqual(
      buildHookCommand(SCRIPT, { platform: "win32", vbsPath: null, requiresStdio: false }),
      `node "${SCRIPT}"`
    );
  });

  test("backslashes in the VBS path are normalised", () => {
    // The command is written into settings.json, where a backslash needs
    // escaping; forward slashes round-trip and Windows accepts them.
    const cmd = buildHookCommand(SCRIPT, {
      platform: "win32",
      vbsPath: "C:\\tools\\openwolf\\dist\\assets\\hook-runner.vbs",
      requiresStdio: false,
    });
    assert.ok(!cmd.includes("\\"), `command still contains a backslash: ${cmd}`);
    assert.ok(cmd.includes("C:/tools/openwolf/dist/assets/hook-runner.vbs"));
  });

  test("the script path is passed through untouched", () => {
    // buildHookCommand does not invent path syntax — hook-manifest.ts owns
    // that, including the absolute-path decision and its history.
    const odd = "C:/a b/proj/.wolf/hooks/pre-bash.js";
    assert.ok(buildHookCommand(odd, { platform: "win32", vbsPath: VBS, requiresStdio: false })
      .endsWith(`node "${odd}"`));
  });
});
