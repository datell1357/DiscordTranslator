// 앱 아이콘을 그린다. 사용법: swift tools/make-icon.swift 출력.png
// 그 뒤 sips로 크기별로 줄이고 iconutil로 Resources/AppIcon.icns를 만든다(tools/make-icon.sh).
import AppKit

let canvas = 1024
let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: canvas, pixelsHigh: canvas,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(
        srgbRed: CGFloat(hex >> 16 & 0xFF) / 255,
        green: CGFloat(hex >> 8 & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

// 맥 아이콘 격자: 1024 안에 824, 모서리 185.
let base = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
NSGradient(starting: color(0x12C2A9), ending: color(0x0B4F8A))!.draw(in: base, angle: -90)

func bubble(_ rect: NSRect, tailLeft: Bool) -> NSBezierPath {
    let path = NSBezierPath(roundedRect: rect, xRadius: 76, yRadius: 76)
    let tail = NSBezierPath()
    let x = tailLeft ? rect.minX + 84 : rect.maxX - 84
    let direction: CGFloat = tailLeft ? -1 : 1
    tail.move(to: NSPoint(x: x - direction * 40, y: rect.minY + 8))
    tail.line(to: NSPoint(x: x + direction * 44, y: rect.minY - 62))
    tail.line(to: NSPoint(x: x + direction * 40, y: rect.minY + 8))
    tail.close()
    // 꼬리를 말풍선과 같은 방향으로 그려야 겹친 곳이 비어 보이지 않는다.
    path.append(tailLeft ? tail.reversed : tail)
    return path
}

func draw(_ text: String, in rect: NSRect, size: CGFloat, color textColor: NSColor) {
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: .bold),
        .foregroundColor: textColor,
    ]
    let string = NSAttributedString(string: text, attributes: attributes)
    let box = string.size()
    string.draw(at: NSPoint(x: rect.midX - box.width / 2, y: rect.midY - box.height / 2))
}

let back = NSRect(x: 196, y: 492, width: 400, height: 320)
color(0xFFFFFF, 0.32).setFill()
bubble(back, tailLeft: true).fill()
// 앞 말풍선에 가리지 않는 윗부분에 놓는다.
draw("A", in: NSRect(x: 196, y: 600, width: 320, height: 212), size: 190, color: .white)

let front = NSRect(x: 412, y: 268, width: 420, height: 340)
color(0xFFFFFF).setFill()
bubble(front, tailLeft: false).fill()
draw("가", in: front, size: 220, color: color(0x0B4F8A))

try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
