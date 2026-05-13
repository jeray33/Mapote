import { copyFileSync, existsSync, mkdirSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const src = resolve(here, "..", "dist", "index.html");
const dst = resolve(here, "..", "..", "Mapote", "editor.html");

if (!existsSync(src)) {
  console.error(`[copy-out] source not found: ${src}`);
  process.exit(1);
}

mkdirSync(dirname(dst), { recursive: true });
copyFileSync(src, dst);
console.log(`[copy-out] wrote ${dst}`);
