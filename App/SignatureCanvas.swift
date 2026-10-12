import AppKit
import MacServices
import PDFEditing
import SwiftUI

/// P29-001/P29-002: a native capture surface for drawn signatures. Pointer
/// strokes are collected here and rendered into an asset by `SignatureCapture`
/// (smoothing, transparency, crop).
final class SignatureCanvasView: NSView {
  private var currentStroke: [CGPoint] = []
  private var strokes: [[CGPoint]] = []
  private var strokeWidth: CGFloat = 3

  override var isFlipped: Bool { true }

  override func mouseDown(with event: NSEvent) {
    currentStroke = [convert(event.locationInWindow, from: nil)]
    needsDisplay = true
  }

  override func mouseDragged(with event: NSEvent) {
    currentStroke.append(convert(event.locationInWindow, from: nil))
    needsDisplay = true
  }

  override func mouseUp(with event: NSEvent) {
    currentStroke.append(convert(event.locationInWindow, from: nil))
    if currentStroke.count > 1 { strokes.append(currentStroke) }
    currentStroke = []
    needsDisplay = true
  }

  func clear() {
    strokes = []
    currentStroke = []
    needsDisplay = true
  }

  var isEmpty: Bool { strokes.isEmpty }

  /// P29-005/P29-006: render the captured strokes into a transparent asset.
  func asset() -> SignatureAsset? {
    guard !strokes.isEmpty else { return nil }
    let converted = (strokes + (currentStroke.count > 1 ? [currentStroke] : [])).map { stroke in
      SignatureCapture.Stroke(
        points: stroke.map { [Double($0.x), Double($0.y)] }, width: Double(strokeWidth))
    }
    let asset = SignatureCapture.render(
      strokes: converted, size: bounds.size)
    return asset.isWellFormed ? asset : nil
  }

  override func draw(_ dirtyRect: NSRect) {
    NSColor.textBackgroundColor.setFill()
    bounds.fill()
    NSColor.separatorColor.setStroke()
    NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5)).stroke()
    NSColor.labelColor.setStroke()
    for stroke in strokes + (currentStroke.count > 1 ? [currentStroke] : []) {
      let path = NSBezierPath()
      path.lineWidth = strokeWidth
      path.lineCapStyle = .round
      path.lineJoinStyle = .round
      path.move(to: stroke[0])
      for point in stroke.dropFirst() { path.line(to: point) }
      path.stroke()
    }
  }
}

/// P29-010/P29-015/P29-016: the capture window with explicit placement and an
/// explicit "save to palette" choice (P29-007).
struct SignatureCanvasPanel: View {
  let canvas: SignatureCanvasView
  var onPlace: (SignatureAsset, Bool) -> Void
  var onCancel: () -> Void

  @State private var saveToPalette = false
  @State private var savedAssets: [SignatureAsset] = []
  @State private var selectedID: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Draw your signature").font(.headline)
      SignatureCanvasRepresentable(canvas: canvas)
        .frame(minWidth: 460, minHeight: 200)
        .border(Color.secondary.opacity(0.3))
      Toggle("Save to my signature palette", isOn: $saveToPalette)
      if !savedAssets.isEmpty {
        HStack {
          Picker("Palette", selection: $selectedID) {
            Text("—").tag(String?.none)
            ForEach(savedAssets, id: \.id) { asset in
              Text("Saved mark \(asset.id.prefix(6))").tag(String?.some(asset.id))
            }
          }
          .frame(maxWidth: 260)
          Button("Place Saved") {
            guard let selectedID,
              let asset = savedAssets.first(where: { $0.id == selectedID })
            else { return }
            onPlace(asset, false)
          }
        }
      }
      HStack {
        Button("Clear") { canvas.clear() }
        Spacer()
        Button("Cancel", action: onCancel)
        Button("Place on Page") {
          if let asset = canvas.asset() { onPlace(asset, saveToPalette) }
        }
        .keyboardShortcut(.defaultAction)
      }
    }
    .padding(14)
    .frame(minWidth: 500)
    .onAppear {
      let store = SignatureAssetStore(directory: SignatureAssetStore.defaultDirectory())
      savedAssets = (try? store.list()) ?? []
    }
  }
}

struct SignatureCanvasRepresentable: NSViewRepresentable {
  let canvas: SignatureCanvasView
  func makeNSView(context: Context) -> SignatureCanvasView { canvas }
  func updateNSView(_ nsView: SignatureCanvasView, context: Context) {}
}
