// Copyright (C) 2026 Conight.
// Draw the installer background without opening windows or scripting Finder.
import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    fputs("Usage: DMGBackground.swift OUTPUT.png\n", stderr)
    exit(64)
}
let image = NSImage(size: NSSize(width: 560, height: 360))
image.lockFocus()
let canvas = NSRect(x: 0, y: 0, width: 560, height: 360)
let gradient = NSGradient(starting: NSColor(calibratedWhite: 0.99, alpha: 1),
                          ending: NSColor(calibratedRed: 0.93, green: 0.96, blue: 0.99, alpha: 1))!
gradient.draw(in: canvas, angle: 270)
let paragraph = NSMutableParagraphStyle()
paragraph.alignment = .center
func label(_ text: String, y: CGFloat, size: CGFloat, weight: NSFont.Weight, color: NSColor) {
    text.draw(in: NSRect(x: 24, y: y, width: 512, height: 36), withAttributes: [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: color, .paragraphStyle: paragraph
    ])
}
label("Install ChopChop", y: 286, size: 25, weight: .semibold,
      color: NSColor(calibratedWhite: 0.12, alpha: 1))
label("Drag ChopChop into Applications.", y: 252, size: 14, weight: .regular,
      color: NSColor(calibratedWhite: 0.38, alpha: 1))
let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: 237, y: 182))
arrow.line(to: NSPoint(x: 323, y: 182))
arrow.move(to: NSPoint(x: 306, y: 199))
arrow.line(to: NSPoint(x: 323, y: 182))
arrow.line(to: NSPoint(x: 306, y: 165))
arrow.lineWidth = 5
arrow.lineCapStyle = .round
arrow.lineJoinStyle = .round
NSColor(calibratedRed: 0, green: 0.45, blue: 0.9, alpha: 1).setStroke()
arrow.stroke()
image.unlockFocus()
guard let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else {
    fputs("Could not render DMG background.\n", stderr)
    exit(1)
}
do {
    try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)
} catch {
    fputs("Could not save DMG background: \(error.localizedDescription)\n", stderr)
    exit(1)
}
