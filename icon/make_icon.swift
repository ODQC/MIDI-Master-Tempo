import AppKit
let size = 1024
let cs = CGColorSpaceCreateDeviceRGB()
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.translateBy(x: 0, y: CGFloat(size)); ctx.scaleBy(x: 1, y: -1)
func c(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor { CGColor(red: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: a) }
func vgrad(_ rect: CGRect, radius: CGFloat, _ top: UInt32, _ bottom: UInt32) {
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)); ctx.clip()
    let g = CGGradient(colorsSpace: cs, colors: [c(top), c(bottom)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(g, start: CGPoint(x: rect.midX, y: rect.minY), end: CGPoint(x: rect.midX, y: rect.maxY), options: [])
    ctx.restoreGState()
}
vgrad(CGRect(x: 100, y: 100, width: 824, height: 824), radius: 185, 0x2b3140, 0x0f1218)
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 40, color: c(0xff4d4d, 0.9))
ctx.setFillColor(c(0xff5a5a)); ctx.fillEllipse(in: CGRect(x: 256, y: 304, width: 92, height: 92))
ctx.restoreGState()
for (x, a) in [(442.0, 1.0), (582.0, 0.45), (722.0, 0.25)] { ctx.setFillColor(c(0xffb020, CGFloat(a))); ctx.fillEllipse(in: CGRect(x: x - 46, y: 304, width: 92, height: 92)) }
for i in 0..<7 { vgrad(CGRect(x: 193 + CGFloat(i) * 92, y: 500, width: 86, height: 330), radius: 14, 0xffffff, 0xdfe3ea) }
for x in [255.3, 347.3, 531.3, 623.3, 715.3] { vgrad(CGRect(x: x, y: 500, width: 53.4, height: 198), radius: 9, 0x3a3f4a, 0x101318) }
let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
