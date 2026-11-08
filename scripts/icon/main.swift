// 마디 앱 아이콘을 그린다 — `make icon`. 1024 좌표로 적은 그림 한 벌을 크기마다 따로(벡터로) 그려
// .iconset에 두고, Makefile이 `iconutil`로 `Sources/Madi/Resources/AppIcon.icns`를 만든다.
//
// 모양: 남색 바탕 위 흰 쪽 한 장. 마크다운 제목 `# 마디`, 문단 두 줄, 맨 아래 마디 셋(초록 막대).
// 2026-11-09에 시안 아홉 가운데 사용자가 고른 것이다(대나무 · 문서 블록 · 한글 '마'와 그 조합들).
// 바탕은 Apple의 macOS 아이콘 격자를 따른다 — 1024 캔버스 안에 824 몸통, 모서리 반지름 185, 아래 그림자.
//
// 글꼴은 앱에 든 것(Pretendard Bold · IBM Plex Mono Bold)을 쓴다. 등록이 안 되면 CoreText가 시스템
// 글꼴로 조용히 바꿔 그리므로, 이름으로 다시 찾아 보고 다르면 멈춘다.
//
// 사용: render <글꼴 폴더> <출력 .iconset 폴더>

import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    FileHandle.standardError.write(Data("사용: render <글꼴 폴더> <출력 .iconset 폴더>\n".utf8))
    exit(2)
}
let fontDirectory = URL(fileURLWithPath: arguments[1])
let iconset = URL(fileURLWithPath: arguments[2])

let headingFont = "Pretendard-Bold"
let markFont = "IBMPlexMono-Bold"
for (file, name) in [("Pretendard-Bold.otf", headingFont), ("IBMPlexMono-Bold.otf", markFont)] {
    // 이미 등록돼 있으면 실패를 돌려주므로 결과는 보지 않고, 이름으로 찾아지는지를 본다.
    CTFontManagerRegisterFontsForURL(fontDirectory.appendingPathComponent(file) as CFURL, .process, nil)
    let resolved = CTFontCopyPostScriptName(CTFontCreateWithName(name as CFString, 12, nil)) as String
    guard resolved == name else {
        FileHandle.standardError.write(Data("글꼴 \(name)을 찾지 못했습니다(대신 \(resolved)) — \(file)\n".utf8))
        exit(1)
    }
}

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func fill(_ ctx: CGContext, _ rect: CGRect, radius: CGFloat, _ fillColor: CGColor) {
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.setFillColor(fillColor)
    ctx.fillPath()
}

func line(_ string: String, font: String, size: CGFloat, color textColor: CGColor? = nil) -> CTLine {
    var attributes: [NSAttributedString.Key: Any] = [.init(kCTFontAttributeName as String): CTFontCreateWithName(font as CFString, size, nil)]
    if let textColor { attributes[.init(kCTForegroundColorAttributeName as String)] = textColor }
    return CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
}

/// 글자의 실제 윤곽(글리프 경로)을 기준으로 가운데를 맞춘다 — 글꼴의 위아래 여백에 휘둘리지 않게.
func draw(_ ctx: CGContext, _ string: String, font: String, size: CGFloat, color textColor: CGColor, center: CGPoint) {
    let textLine = line(string, font: font, size: size, color: textColor)
    let bounds = CTLineGetBoundsWithOptions(textLine, .useGlyphPathBounds)
    ctx.textPosition = CGPoint(x: center.x - bounds.midX, y: center.y - bounds.midY)
    CTLineDraw(textLine, ctx)
}

func glyphWidth(_ string: String, font: String, size: CGFloat) -> CGFloat {
    CTLineGetBoundsWithOptions(line(string, font: font, size: size), .useGlyphPathBounds).width
}

/// 1024 좌표의 아이콘 한 장. `scale`은 그림자에만 쓴다 — CGContext의 그림자 오프셋과 흐림은
/// 좌표 변환을 따르지 않고 장치 픽셀로 적용되기 때문이다(안 맞추면 16px에서 그림자가 아이콘을 덮는다).
func drawIcon(_ ctx: CGContext, scale: CGFloat) {
    let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

    // 바탕 — 남색, 위가 밝다.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12 * scale), blur: 24 * scale, color: color(0x000000, 0.28))
    ctx.addPath(bodyPath)
    ctx.setFillColor(color(0x18223F))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: srgb, colors: [color(0x2E4373), color(0x18223F)] as CFArray, locations: nil)!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    ctx.restoreGState()

    // 쪽 한 장.
    let page = CGRect(x: 232, y: 168, width: 560, height: 688)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * scale), blur: 30 * scale, color: color(0x000000, 0.35))
    fill(ctx, page, radius: 44, color(0xFFFFFF))
    ctx.restoreGState()
    let left = page.minX + 60
    let width = page.width - 120

    // 제목 `# 마디` — 마크다운처럼 '#' 다음에 빈칸 하나(코드 글꼴의 빈칸 폭 0.6em). 쪽 안 폭에 맞춘다.
    func parts(_ size: CGFloat) -> (mark: CGFloat, space: CGFloat, word: CGFloat) {
        let markSize = size * 0.62
        return (glyphWidth("#", font: markFont, size: markSize), markSize * 0.6, glyphWidth("마디", font: headingFont, size: size))
    }
    var size: CGFloat = 300
    while size > 40 {
        let p = parts(size)
        if p.mark + p.space + p.word <= width { break }
        size -= 2
    }
    let p = parts(size)
    let headingY: CGFloat = 690
    draw(ctx, "#", font: markFont, size: size * 0.62, color: color(0xE8573F), center: CGPoint(x: left + p.mark / 2, y: headingY))
    draw(ctx, "마디", font: headingFont, size: size, color: color(0x1F2328),
         center: CGPoint(x: left + p.mark + p.space + p.word / 2, y: headingY))

    // 문단 두 줄.
    for (index, lineWidth) in [440.0, 330.0].enumerated() {
        fill(ctx, CGRect(x: left, y: 478 - CGFloat(index) * 56, width: lineWidth, height: 28), radius: 14, color(0xC5CCD6))
    }

    // 마디 셋.
    let gap: CGFloat = 24, barHeight: CGFloat = 40
    let segment = (width - 2 * gap) / 3
    for (index, hex) in [UInt32(0x3FB950), 0x56D364, 0x2EA043].enumerated() {
        fill(ctx, CGRect(x: left + CGFloat(index) * (segment + gap), y: 262, width: segment, height: barHeight),
             radius: barHeight / 2, color(hex))
    }
}

func render(pixels: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    let scale = CGFloat(pixels) / 1024
    ctx.scaleBy(x: scale, y: scale)
    drawIcon(ctx, scale: scale)
    return ctx.makeImage()!
}

// iconutil이 읽는 이름과 크기.
let entries: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for entry in entries {
    let url = iconset.appendingPathComponent("\(entry.name).png")
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        FileHandle.standardError.write(Data("쓸 수 없습니다: \(url.path)\n".utf8))
        exit(1)
    }
    CGImageDestinationAddImage(destination, render(pixels: entry.pixels), nil)
    guard CGImageDestinationFinalize(destination) else {
        FileHandle.standardError.write(Data("PNG를 쓰지 못했습니다: \(url.path)\n".utf8))
        exit(1)
    }
}
print("\(entries.count)장 → \(iconset.path)")
