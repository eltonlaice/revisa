// Renders an SVG to PNG: swift scripts/render-svg.swift in.svg out.png width
import AppKit
let a = CommandLine.arguments
let img = NSImage(contentsOf: URL(fileURLWithPath: a[1]))!
let w = Int(a[3])!, h = Int(Double(w) * img.size.height / img.size.width)
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
img.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: a[2]))
