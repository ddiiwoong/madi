// 편집기를 dist/로 묶는다 — WPF 호스트가 그 폴더를 `https://app.madi/`로 연다(`Madi.Windows.csproj`가 옮긴다).
//
// - main.js: src/main.ts와 CodeMirror를 한 파일로(esbuild).
// - index.html · style.css, 글꼴(macOS판과 같은 파일 — 한 곳에서만 고친다).
// - THIRD-PARTY.txt: 묶음에 든 npm 꾸러미의 라이선스 전문(모두 MIT). 묶으면 소스의 라이선스 줄이 남지 않아 따로 모은다.

import { build } from "esbuild";
import { copyFile, mkdir, readFile, readdir, rm, writeFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import path from "node:path";

const root = path.dirname(fileURLToPath(import.meta.url));
const dist = path.join(root, "dist");
const fonts = path.join(root, "..", "..", "Sources", "Madi", "Resources", "Fonts");

await rm(dist, { recursive: true, force: true });
await mkdir(path.join(dist, "fonts"), { recursive: true });

const result = await build({
  absWorkingDir: root,
  entryPoints: ["src/main.ts"],
  outfile: path.join(dist, "main.js"),
  bundle: true,
  format: "esm",
  target: "chrome120",
  minify: true,
  sourcemap: "linked",
  legalComments: "none",
  metafile: true,
  logLevel: "warning",
});

for (const file of ["index.html", "style.css"]) {
  await copyFile(path.join(root, file), path.join(dist, file));
}
const fontFiles = [
  "Pretendard-Regular.otf", "Pretendard-Bold.otf", "OFL-Pretendard.txt",
  "IBMPlexMono-Regular.otf", "IBMPlexMono-Bold.otf", "IBMPlexMono-Italic.otf", "IBMPlexMono-BoldItalic.otf",
  "OFL-IBMPlexMono.txt",
];
for (const file of fontFiles) {
  await copyFile(path.join(fonts, file), path.join(dist, "fonts", file));
}

// 묶음에 들어간 꾸러미 — 메타파일의 입력 경로에서 node_modules/<이름>을 뽑는다.
const packages = new Set();
for (const input of Object.keys(result.metafile.inputs)) {
  const match = input.match(/node_modules\/((?:@[^/]+\/)?[^/]+)\//);
  if (match) packages.add(match[1]);
}
const notices = [];
for (const name of [...packages].sort()) {
  const dir = path.join(root, "node_modules", name);
  const manifest = JSON.parse(await readFile(path.join(dir, "package.json"), "utf8"));
  const licenseFile = (await readdir(dir)).find((file) => /^licen[cs]e/i.test(file));
  if (!licenseFile) throw new Error(`${name}: 라이선스 파일이 없다 — 묶어 낼 수 없다`);
  const text = await readFile(path.join(dir, licenseFile), "utf8");
  notices.push(`${name} ${manifest.version} (${manifest.license})\n\n${text.trim()}\n`);
}
await writeFile(path.join(dist, "THIRD-PARTY.txt"),
  "마디 Windows판의 편집기에 묶인 꾸러미와 그 라이선스입니다.\n\n" + notices.join("\n" + "-".repeat(72) + "\n\n"));

const size = (await readFile(path.join(dist, "main.js"))).length;
console.log(`dist/main.js ${(size / 1024).toFixed(0)} KB · 꾸러미 ${packages.size}개 · 글꼴 파일 ${fontFiles.length}개`);
