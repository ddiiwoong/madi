#!/usr/bin/env python3
"""Windows판 아이콘을 macOS판 아이콘에서 만든다 — 이 Mac에서(iconutil · sips). 결과는 저장소에 둔다(빌드가 이것에 기대지 않게).

- windows/msix/Assets/*.png — MSIX의 타일 · 작업 표시줄 · Store 로고(크기 · 배율마다, `makepri`가 고른다)
- windows/Madi.Windows/Madi.ico — exe 아이콘(설치 파일 · 탐색기 · 창 제목 줄)

원본은 `Sources/Madi/Resources/AppIcon.icns`(`make icon`이 그린 것)다. 크기마다 그보다 크거나 같은 가장 작은 그림에서 줄인다 —
16 · 32는 macOS판이 그 크기로 따로 그린 것을 그대로 쓴다.

사용: python3 windows/msix/make-assets.py
"""

import pathlib
import shutil
import struct
import subprocess
import tempfile

root = pathlib.Path(__file__).resolve().parents[2]
icns = root / "Sources" / "Madi" / "Resources" / "AppIcon.icns"
assets = root / "windows" / "msix" / "Assets"
ico = root / "windows" / "Madi.Windows" / "Madi.ico"

# MSIX 로고 — (파일 이름, 한 변). 이름의 `scale-…` · `targetsize-…`는 makepri의 한정자다 — 매니페스트는 한정자 없는 이름
# (`Assets\Square44x44Logo.png`)을 적고, Windows가 resources.pri에서 화면에 맞는 것을 고른다(Visual Studio의 꾸러미와 같은 꼴).
square44 = [
    (f"Square44x44Logo.scale-{scale}.png", round(44 * scale / 100)) for scale in (100, 125, 150, 200, 400)
] + [
    (f"Square44x44Logo.targetsize-{size}{plate}.png", size)
    for size in (16, 24, 32, 48, 256)
    for plate in ("", "_altform-unplated")
]
square150 = [
    (f"Square150x150Logo.scale-{scale}.png", round(150 * scale / 100)) for scale in (100, 125, 150, 200, 400)
]
store = [(f"StoreLogo.scale-{scale}.png", round(50 * scale / 100)) for scale in (100, 125, 150, 200, 400)]
ico_sizes = [16, 20, 24, 32, 40, 48, 64, 256]


def sources(iconset: pathlib.Path) -> list[tuple[int, pathlib.Path]]:
    found = []
    for path in iconset.glob("*.png"):
        width = int(subprocess.run(["sips", "-g", "pixelWidth", str(path)], capture_output=True, text=True, check=True)
                    .stdout.split()[-1])
        found.append((width, path))
    return sorted(found)


def render(available: list[tuple[int, pathlib.Path]], size: int, out: pathlib.Path) -> None:
    width, source = next((width, path) for width, path in available if width >= size)
    if width == size:
        shutil.copyfile(source, out)
    else:
        subprocess.run(["sips", "-z", str(size), str(size), str(source), "--out", str(out)], capture_output=True, check=True)


def write_ico(images: list[tuple[int, bytes]], out: pathlib.Path) -> None:
    """PNG를 그대로 담은 ICO(Windows Vista부터 읽는다). 256은 크기 칸에 0을 적는 것이 약속이다."""
    header = struct.pack("<HHH", 0, 1, len(images))
    offset = 6 + 16 * len(images)
    entries = b""
    for size, data in images:
        side = 0 if size >= 256 else size
        entries += struct.pack("<BBBBHHII", side, side, 0, 0, 1, 32, len(data), offset)
        offset += len(data)
    out.write_bytes(header + entries + b"".join(data for _, data in images))


def main() -> None:
    with tempfile.TemporaryDirectory() as temp:
        iconset = pathlib.Path(temp) / "AppIcon.iconset"
        subprocess.run(["iconutil", "-c", "iconset", str(icns), "-o", str(iconset)], check=True)
        available = sources(iconset)
        if assets.exists():
            shutil.rmtree(assets)
        assets.mkdir(parents=True)
        for name, size in square44 + square150 + store:
            render(available, size, assets / name)
        images = []
        for size in ico_sizes:
            out = pathlib.Path(temp) / f"ico-{size}.png"
            render(available, size, out)
            images.append((size, out.read_bytes()))
        write_ico(images, ico)
    print(f"{len(list(assets.glob('*.png')))} PNG → {assets.relative_to(root)}, {ico.relative_to(root)} ({ico.stat().st_size} B)")


if __name__ == "__main__":
    main()
