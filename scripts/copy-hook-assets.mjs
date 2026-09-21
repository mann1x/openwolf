// Copy the hook launcher's C# source into dist/assets so it ships in the
// tarball (package.json `files` publishes dist/ only). The binary itself is
// NOT built here: csc.exe is Windows-only and the package is built on Linux,
// so src/utils/hook-command.ts compiles it on demand at init/update time on
// the machine that needs it.
import { copyFileSync, mkdirSync, existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const repo = dirname(dirname(fileURLToPath(import.meta.url)));
const src = join(repo, "assets", "hook-launcher.cs");
const outDir = join(repo, "dist", "assets");
if (!existsSync(src)) {
  console.error("copy-hook-assets: assets/hook-launcher.cs is missing");
  process.exit(1);
}
mkdirSync(outDir, { recursive: true });
copyFileSync(src, join(outDir, "hook-launcher.cs"));
console.log("copy-hook-assets: dist/assets/hook-launcher.cs");
