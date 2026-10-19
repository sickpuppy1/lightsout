// Draws the LightsOut app icon (crescent moon on a night-sky squircle) and writes assets/AppIcon.icns.
// Run from the repo root:  swift assets/make-icon.swift
import AppKit

func draw(_ px: Int) -> Data {
  let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                             samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                             bytesPerRow: 0, bitsPerPixel: 0)!
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
  let s = CGFloat(px) / 1024  // design on Apple's 1024 grid: 824pt body, 100pt margin, ~185pt corner radius
  let body = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
  let squircle = NSBezierPath(roundedRect: body, xRadius: 185 * s, yRadius: 185 * s)
  NSGradient(starting: NSColor(srgbRed: 0.16, green: 0.18, blue: 0.36, alpha: 1),
             ending: NSColor(srgbRed: 0.02, green: 0.02, blue: 0.07, alpha: 1))!.draw(in: squircle, angle: -90)

  NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.85).setFill()
  for (x, y, r) in [(300.0, 740.0, 9.0), (720.0, 770.0, 12.0), (790.0, 560.0, 7.0), (250.0, 330.0, 7.0), (640.0, 250.0, 8.0)] {
    NSBezierPath(ovalIn: NSRect(x: (x - r) * s, y: (y - r) * s, width: 2 * r * s, height: 2 * r * s)).fill()
  }

  // Crescent = moon disc clipped by "everything except an offset disc".
  let moon = NSRect(x: 292 * s, y: 292 * s, width: 440 * s, height: 440 * s)
  let bite = NSRect(x: 420 * s, y: 380 * s, width: 400 * s, height: 400 * s)
  NSGraphicsContext.saveGraphicsState()
  let clip = NSBezierPath(rect: body); clip.append(NSBezierPath(ovalIn: bite)); clip.windingRule = .evenOdd
  clip.addClip()
  NSColor(srgbRed: 0.99, green: 0.93, blue: 0.76, alpha: 1).setFill()
  NSBezierPath(ovalIn: moon).fill()
  NSGraphicsContext.restoreGraphicsState()

  NSGraphicsContext.restoreGraphicsState()
  return rep.representation(using: .png, properties: [:])!
}

let set = URL(fileURLWithPath: "assets/AppIcon.iconset")
try? FileManager.default.removeItem(at: set)
try! FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
for pt in [16, 32, 128, 256, 512] {
  try! draw(pt).write(to: set.appendingPathComponent("icon_\(pt)x\(pt).png"))
  try! draw(pt * 2).write(to: set.appendingPathComponent("icon_\(pt)x\(pt)@2x.png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", set.path, "-o", "assets/AppIcon.icns"]
try! p.run(); p.waitUntilExit()
try? FileManager.default.removeItem(at: set)
try! draw(1024).write(to: URL(fileURLWithPath: "assets/icon.png"))  // for the README
print("wrote assets/AppIcon.icns")
