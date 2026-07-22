import AppKit
import SwiftUI
import XCTest

@testable import Liltfinch

@MainActor
final class ArtworkViewTests: XCTestCase {
  func testWideArtworkDoesNotDrawOutsideItsLayoutFrame() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("LiltfinchArtworkTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let artworkURL = directory.appendingPathComponent("wide-artwork.png")
    try Self.writeWideArtwork(to: artworkURL)

    let renderer = ImageRenderer(
      content:
        HStack(spacing: 0) {
          ArtworkView(remoteURL: nil, localURL: artworkURL, cornerRadius: 0)
            .frame(width: 58, height: 58)
          Color.clear.frame(width: 58, height: 58)
        }
        .frame(width: 116, height: 58)
        .background(Color.white)
    )
    renderer.scale = 1

    let renderedImage = try XCTUnwrap(renderer.nsImage)
    let bitmap = try XCTUnwrap(renderedImage.tiffRepresentation.flatMap(NSBitmapImageRep.init))
    let artworkPixel = try XCTUnwrap(bitmap.colorAt(x: 29, y: 29)?.usingColorSpace(.deviceRGB))
    let adjacentPixel = try XCTUnwrap(bitmap.colorAt(x: 70, y: 29)?.usingColorSpace(.deviceRGB))

    XCTAssertGreaterThan(artworkPixel.redComponent, 0.9)
    XCTAssertGreaterThan(artworkPixel.redComponent, artworkPixel.greenComponent * 4)
    XCTAssertGreaterThan(adjacentPixel.redComponent, 0.9)
    XCTAssertGreaterThan(adjacentPixel.greenComponent, 0.9)
    XCTAssertGreaterThan(adjacentPixel.blueComponent, 0.9)
  }

  private static func writeWideArtwork(to url: URL) throws {
    let representation = try XCTUnwrap(
      NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: 160,
        pixelsHigh: 90,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
      )
    )
    representation.size = NSSize(width: 160, height: 90)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: representation)
    NSColor.red.setFill()
    NSRect(x: 0, y: 0, width: 160, height: 90).fill()
    NSGraphicsContext.restoreGraphicsState()

    let data = try XCTUnwrap(representation.representation(using: .png, properties: [:]))
    try data.write(to: url, options: .atomic)
  }
}
