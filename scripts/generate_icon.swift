import AppKit

// 生成 TT 的深色终端风格应用图标，输出到 iOS 资源目录。
let size = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

let bounds = NSRect(x: 0, y: 0, width: size, height: size)
NSColor(calibratedRed: 0.025, green: 0.045, blue: 0.075, alpha: 1).setFill()
bounds.fill()

let iconRect = NSRect(x: 44, y: 44, width: 936, height: 936)
let iconPath = NSBezierPath(roundedRect: iconRect, xRadius: 210, yRadius: 210)
let gradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.04, green: 0.95, blue: 0.72, alpha: 1),
    NSColor(calibratedRed: 0.02, green: 0.62, blue: 0.95, alpha: 1)
])!
gradient.draw(in: iconPath, angle: -45)

let innerRect = iconRect.insetBy(dx: 15, dy: 15)
let innerPath = NSBezierPath(roundedRect: innerRect, xRadius: 195, yRadius: 195)
NSColor(calibratedRed: 0.025, green: 0.055, blue: 0.09, alpha: 1).setFill()
innerPath.fill()

let prompt = NSBezierPath()
prompt.lineWidth = 48
prompt.lineCapStyle = .round
prompt.lineJoinStyle = .round
prompt.move(to: NSPoint(x: 300, y: 635))
prompt.line(to: NSPoint(x: 445, y: 520))
prompt.line(to: NSPoint(x: 300, y: 405))
NSColor(calibratedRed: 0.12, green: 1.0, blue: 0.69, alpha: 1).setStroke()
prompt.stroke()

let cursor = NSBezierPath(roundedRect: NSRect(x: 490, y: 382, width: 185, height: 42), xRadius: 18, yRadius: 18)
NSColor(calibratedRed: 0.12, green: 1.0, blue: 0.69, alpha: 1).setFill()
cursor.fill()

let attributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 142, weight: .bold),
    .foregroundColor: NSColor.white
]
let title = NSAttributedString(string: "TT", attributes: attributes)
let titleSize = title.size()
title.draw(at: NSPoint(x: (CGFloat(size) - titleSize.width) / 2, y: 155))

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("无法生成 TT 应用图标")
}

let output = "TT/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
try FileManager.default.createDirectory(
    at: URL(fileURLWithPath: output).deletingLastPathComponent(),
    withIntermediateDirectories: true
)
try png.write(to: URL(fileURLWithPath: output))
print("已生成应用图标：\(output)")
