// MacDroid 앱 아이콘 렌더러 — CoreGraphics로 1024px PNG 생성.
// 사용: swift scripts/gen-icon.swift <출력경로.png>
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write("usage: swift gen-icon.swift <output.png>\n".data(using: .utf8)!)
    exit(1)
}
let outputURL = URL(fileURLWithPath: args[1])
let size = 1024

// --- 캔버스 ---
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(
    data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
    space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
)!

func rgba(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: a
    )
}

// 배경: macOS 라운디드 스퀘어, 딥 네이비→브라이트 블루 그라디언트
let rect = CGRect(x: 0, y: 0, width: size, height: size)
let radius = CGFloat(size) * 0.2237 // Apple 아이콘 곡률
let bgPath = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
ctx.saveGState()
ctx.addPath(bgPath)
ctx.clip()
let gradient = CGGradient(
    colorsSpace: colorSpace,
    colors: [rgba(0x0B1B3F), rgba(0x1D4ED8), rgba(0x38BDF8)] as CFArray,
    locations: [0.0, 0.55, 1.0]
)!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: CGFloat(size)), end: CGPoint(x: CGFloat(size), y: 0), options: [])

// 은은한 상단 광택
let gloss = CGGradient(colorsSpace: colorSpace, colors: [rgba(0xFFFFFF, 0.22), rgba(0xFFFFFF, 0.0)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(gloss, start: CGPoint(x: 0, y: CGFloat(size)), end: CGPoint(x: 0, y: CGFloat(size) * 0.45), options: [])
ctx.restoreGState()

// --- 맥 윈도우 카드 ---
let s = CGFloat(size)
let cardRect = CGRect(x: s * 0.20, y: s * 0.24, width: s * 0.60, height: s * 0.52)
let cardPath = CGPath(roundedRect: cardRect, cornerWidth: s * 0.045, cornerHeight: s * 0.045, transform: nil)

// 카드 그림자
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.015), blur: s * 0.03, color: rgba(0x000000, 0.35))
ctx.addPath(cardPath)
ctx.setFillColor(rgba(0xF8FAFC, 0.97))
ctx.fillPath()
ctx.restoreGState()

// 타이틀바
let titlebarRect = CGRect(x: cardRect.minX, y: cardRect.maxY - s * 0.09, width: cardRect.width, height: s * 0.09)
ctx.saveGState()
ctx.addPath(cardPath)
ctx.clip()
ctx.setFillColor(rgba(0xE2E8F0))
ctx.fill(titlebarRect)
// 트래픽 라이트
let dotY = titlebarRect.midY
let dotR = s * 0.012
let dotXs: [CGFloat] = [cardRect.minX + s * 0.05, cardRect.minX + s * 0.085, cardRect.minX + s * 0.12]
let dotColors: [UInt32] = [0xFF5F57, 0xFEBC2E, 0x28C840]
for (i, dx) in dotXs.enumerated() {
    ctx.setFillColor(rgba(dotColors[i]))
    ctx.fillEllipse(in: CGRect(x: dx - dotR, y: dotY - dotR, width: dotR * 2, height: dotR * 2))
}
ctx.restoreGState()

// --- 폰 실루엣 (윈도우 안에 떠 있는 안드로이드 폰) ---
let phoneW = s * 0.22
let phoneH = s * 0.36
let phoneRect = CGRect(
    x: cardRect.midX - phoneW / 2,
    y: cardRect.minY + (cardRect.height - s * 0.09) / 2 - phoneH / 2 + s * 0.01,
    width: phoneW, height: phoneH
)
// 폰 그림자
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.008), blur: s * 0.02, color: rgba(0x000000, 0.30))
ctx.addPath(CGPath(roundedRect: phoneRect, cornerWidth: s * 0.028, cornerHeight: s * 0.028, transform: nil))
ctx.setFillColor(rgba(0x111827))
ctx.fillPath()
ctx.restoreGState()

// 폰 스크린(안드로이드 초록 화면)
let screenInset = s * 0.012
let screenRect = phoneRect.insetBy(dx: screenInset, dy: screenInset * 2.4)
ctx.addPath(CGPath(roundedRect: screenRect, cornerWidth: s * 0.018, cornerHeight: s * 0.018, transform: nil))
let screenGrad = CGGradient(colorsSpace: colorSpace, colors: [rgba(0x22C55E), rgba(0x16A34A)] as CFArray, locations: [0, 1])!
ctx.saveGState()
ctx.addPath(CGPath(roundedRect: screenRect, cornerWidth: s * 0.018, cornerHeight: s * 0.018, transform: nil))
ctx.clip()
ctx.drawLinearGradient(screenGrad, start: CGPoint(x: 0, y: screenRect.maxY), end: CGPoint(x: 0, y: screenRect.minY), options: [])
// 안드로이드 로봇 헤드
let headCx = screenRect.midX
let headCy = screenRect.midY + screenRect.height * 0.08
let headW = screenRect.width * 0.44
let headH = headW * 0.62
ctx.setFillColor(rgba(0xFFFFFF, 0.96))
// 머리(반원)
ctx.beginPath()
ctx.addArc(center: CGPoint(x: headCx, y: headCy), radius: headW / 2, startAngle: 0, endAngle: .pi, clockwise: false)
ctx.closePath()
ctx.fillPath()
// 눈
let eyeR = headW * 0.052
let eyeOffset = headW * 0.22
ctx.setFillColor(rgba(0x16A34A))
ctx.fillEllipse(in: CGRect(x: headCx - eyeOffset - eyeR, y: headCy - headH * 0.42 - eyeR, width: eyeR * 2, height: eyeR * 2))
ctx.fillEllipse(in: CGRect(x: headCx + eyeOffset - eyeR, y: headCy - headH * 0.42 - eyeR, width: eyeR * 2, height: eyeR * 2))
// 안테나
ctx.setStrokeColor(rgba(0xFFFFFF, 0.96))
ctx.setLineWidth(s * 0.008)
ctx.setLineCap(.round)
ctx.addLines(between: [CGPoint(x: headCx - headW * 0.28, y: headCy + headH * 0.28), CGPoint(x: headCx - headW * 0.42, y: headCy + headH * 0.62)])
ctx.addLines(between: [CGPoint(x: headCx + headW * 0.28, y: headCy + headH * 0.28), CGPoint(x: headCx + headW * 0.42, y: headCy + headH * 0.62)])
ctx.strokePath()
ctx.restoreGState()

// --- 좌하단 연결 곡선(USB 링크 표현) ---
ctx.setStrokeColor(rgba(0xFFFFFF, 0.85))
ctx.setLineWidth(s * 0.016)
ctx.setLineCap(.round)
let curveStart = CGPoint(x: cardRect.minX + s * 0.04, y: cardRect.minY + s * 0.05)
let curveEnd = CGPoint(x: phoneRect.minX + phoneW * 0.1, y: phoneRect.maxY + s * 0.06)
ctx.beginPath()
ctx.move(to: curveStart)
ctx.addQuadCurve(to: curveEnd, control: CGPoint(x: cardRect.minX - s * 0.02, y: phoneRect.midY))
ctx.strokePath()
// 커넥터 점
ctx.setFillColor(rgba(0xFFFFFF, 0.9))
ctx.fillEllipse(in: CGRect(x: curveStart.x - s * 0.012, y: curveStart.y - s * 0.012, width: s * 0.024, height: s * 0.024))

// --- 저장 ---
let image = ctx.makeImage()!
let dest = CGImageDestinationCreateWithURL(outputURL as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, image, nil)
CGImageDestinationFinalize(dest)
print("icon written: \(outputURL.path)")
