import Foundation
import PDFCore

/// P13-005–P13-023: a bounded content-stream interpreter that tracks graphics
/// and text state, marked content, and draw instructions without rendering.
/// Nothing here writes bytes: it is an analysis layer for editing safety.
public struct ContentTrace: Sendable, Equatable {
  public struct DrawInstruction: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
      case text
      case image
      case form
      case path
      case shading
    }

    public let kind: Kind
    public let instructionIndex: Int
    /// Conservative bounds in page space after the CTM (clipped).
    public let bounds: [Double]
    /// Font resource name for text runs.
    public let fontName: String?
    public let fontSize: Double?
    /// Resource name for images/forms/shading patterns.
    public let resourceName: String?
    /// True for invisible or clipping text rendering modes.
    public let isInvisibleText: Bool
    public let text: String?
  }

  public struct MarkedContentSpan: Sendable, Equatable {
    public let mcid: Int?
    public let tag: String?
    public let startInstruction: Int
    public let endInstruction: Int
    public let optionalContentName: String?
  }

  public struct Diagnostic: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
      case unbalancedGraphicsStack
      case unbalancedTextObject
      case inlineImageOpaque
      case unknownOperator
      case missingResource
      case depthLimit
    }

    public let kind: Kind
    public let instructionIndex: Int
    public let detail: String
  }

  public let draws: [DrawInstruction]
  public let markedContent: [MarkedContentSpan]
  public let diagnostics: [Diagnostic]
  /// Conservative visible bounds of everything drawn (page space).
  public let visibleBounds: [Double]?
  /// Resource names that appear on more than one page or form and therefore
  /// need copy-on-write before an in-place edit (P13-025).
  public let sharedResourceNames: [String]
}

public enum ContentInterpreter {
  public struct Limits: Sendable {
    public var maxInstructions: Int
    public var maxFormDepth: Int
    public var maxDraws: Int

    public init(maxInstructions: Int = 200_000, maxFormDepth: Int = 16, maxDraws: Int = 100_000) {
      self.maxInstructions = maxInstructions
      self.maxFormDepth = maxFormDepth
      self.maxDraws = maxDraws
    }
  }

  /// P13-005–P13-023: interpret a page's content (and nested forms) and report
  /// what is drawn, where, and with which state.
  public static func trace(
    pageID: PDFObjectID, in graph: PDFGraph, limits: Limits = Limits()
  ) throws -> ContentTrace {
    let content = try PageContent.load(pageID: pageID, in: graph)
    let page: [PDFName: PDFValue]?
    if case .dictionary(let dictionary)? = graph.objects[pageID] {
      page = dictionary
    } else {
      page = nil
    }
    let resources = page.flatMap { resourceDictionary(of: $0, in: graph) } ?? [:]
    var collector = Collector(limits: limits)
    try collector.run(
      instructions: content.instructions, resources: resources, graph: graph, depth: 0,
      initialCTM: [1, 0, 0, 1, 0, 0])
    let shared = try sharedResourceNames(pageIDs: [pageID], in: graph)
    return ContentTrace(
      draws: collector.draws, markedContent: collector.marked, diagnostics: collector.diagnostics,
      visibleBounds: collector.visibleBounds, sharedResourceNames: shared)
  }

  /// P13-025: resource names reachable from more than one page (or used by a
  /// form and a page) that an in-place edit must copy before changing.
  public static func sharedResourceNames(
    pageIDs: [PDFObjectID], in graph: PDFGraph
  ) throws -> [String] {
    var owners: [String: Set<String>] = [:]
    for pageID in pageIDs {
      guard case .dictionary(let page)? = graph.objects[pageID],
        let resources = resourceDictionary(of: page, in: graph)
      else { continue }
      for category in ["Font", "XObject", "ExtGState", "ColorSpace", "Pattern", "Shading"] {
        guard case .dictionary(let entries)? = resources[PDFName(category)] else { continue }
        for (name, value) in entries {
          guard case .reference(let id) = value else { continue }
          owners["\(category):\(String(decoding: name.bytes, as: UTF8.self))", default: []]
            .insert("\(pageID.number)")
          _ = id
        }
      }
    }
    return owners.filter { $0.value.count > 1 }.keys.sorted()
  }

  static func resourceDictionary(
    of page: [PDFName: PDFValue], in graph: PDFGraph
  ) -> [PDFName: PDFValue]? {
    switch page[PDFName("Resources")] {
    case .dictionary(let dictionary)?:
      return dictionary
    case .reference(let id)?:
      if case .dictionary(let dictionary)? = graph.objects[id] { return dictionary }
      return nil
    default:
      return nil
    }
  }

  // MARK: - Interpreter

  struct Collector {
    let limits: Limits
    var draws: [ContentTrace.DrawInstruction] = []
    var marked: [ContentTrace.MarkedContentSpan] = []
    var diagnostics: [ContentTrace.Diagnostic] = []
    var visibleBounds: [Double]?

    struct State {
      var ctm: [Double] = [1, 0, 0, 1, 0, 0]
      var clip: [Double]?  // conservative page-space clip bounds
      var lineWidth: Double = 1
      var lineCap: Int = 0
      var lineJoin: Int = 0
      var dash: [Double] = []
      var miterLimit: Double = 10
      var strokeColor: String = ""
      var fillColor: String = ""
      var alpha: Double = 1
      var fontName: String?
      var fontSize: Double = 12
      var textRenderingMode: Int = 0
      var textRise: Double = 0
      var charSpacing: Double = 0
      var wordSpacing: Double = 0
      var horizontalScale: Double = 100
      var leading: Double = 0
      var textMatrix: [Double] = [1, 0, 0, 1, 0, 0]
      var lineMatrix: [Double] = [1, 0, 0, 1, 0, 0]
      var pendingPath: [[Double]] = []
    }

    mutating func run(
      instructions: [ContentInstruction], resources: [PDFName: PDFValue], graph: PDFGraph,
      depth: Int, initialCTM: [Double]
    ) throws {
      guard depth <= limits.maxFormDepth else {
        diagnostics.append(
          ContentTrace.Diagnostic(
            kind: .depthLimit, instructionIndex: 0, detail: "Form nesting limit reached"))
        return
      }
      var stack: [State] = []
      var state = State()
      state.ctm = initialCTM
      var markedStack: [(mcid: Int?, tag: String?, start: Int, oc: String?)] = []
      var inTextObject = false
      var budget = limits.maxInstructions

      for (index, instruction) in instructions.enumerated() {
        budget -= 1
        if budget <= 0 { break }
        let operands = numbers(instruction.operands)
        switch instruction.operatorName {
        case "q":
          stack.append(state)
          if stack.count > 1_000 {
            diagnostics.append(
              ContentTrace.Diagnostic(
                kind: .depthLimit, instructionIndex: index,
                detail: "Graphics stack exceeded 1,000 entries"))
            stack.removeFirst(stack.count - 1_000)
          }
        case "Q":
          if let restored = stack.popLast() {
            state = restored
          } else {
            diagnostics.append(
              ContentTrace.Diagnostic(
                kind: .unbalancedGraphicsStack, instructionIndex: index,
                detail: "Q without a matching q"))
          }
        case "cm":
          if let values = operands, values.count == 6 {
            state.ctm = concatenate(state.ctm, values)
          }
        case "w":
          if let values = operands, let width = values.first { state.lineWidth = width }
        case "J":
          if let values = operands, let cap = values.first { state.lineCap = Int(cap) }
        case "j":
          if let values = operands, let join = values.first { state.lineJoin = Int(join) }
        case "M":
          if let values = operands, let limit = values.first { state.miterLimit = limit }
        case "d":
          if case .array(let values)? = instruction.operands.last?.value {
            state.dash = values.compactMap { value -> Double? in
              switch value {
              case .integer(let number): return Double(number)
              case .real(let number): return number
              default: return nil
              }
            }
          }
        case "RG", "rg", "G", "g", "K", "k", "CS", "cs", "SC", "sc", "SCN", "scn":
          if let values = operands, !values.isEmpty {
            let description = "\(instruction.operatorName):"
              + values.map { String(format: "%.2f", $0) }.joined(separator: ",")
            if ["RG", "G", "K", "CS", "SC", "SCN"].contains(instruction.operatorName) {
              state.strokeColor = description
            }
            if ["rg", "g", "k", "cs", "sc", "scn"].contains(instruction.operatorName) {
              state.fillColor = description
            }
          }
        case "gs":
          if case .name(let name)? = instruction.operands.first?.value,
            case .dictionary(let states)? = resources[PDFName("ExtGState")],
            let entry = states[name]
          {
            if case .dictionary(let dictionary)? = resolve(entry, in: graph) {
              for key in ["ca", "CA"] {
                if case .real(let alpha)? = dictionary[PDFName(key)] { state.alpha = alpha }
                if case .integer(let alpha)? = dictionary[PDFName(key)] {
                  state.alpha = Double(alpha)
                }
              }
            }
          }
        case "BT":
          if inTextObject {
            diagnostics.append(
              ContentTrace.Diagnostic(
                kind: .unbalancedTextObject, instructionIndex: index,
                detail: "BT inside a text object"))
          }
          inTextObject = true
          state.textMatrix = [1, 0, 0, 1, 0, 0]
          state.lineMatrix = state.textMatrix
        case "ET":
          if !inTextObject {
            diagnostics.append(
              ContentTrace.Diagnostic(
                kind: .unbalancedTextObject, instructionIndex: index,
                detail: "ET without BT"))
          }
          inTextObject = false
        case "Tf":
          if case .name(let name)? = instruction.operands.first?.value {
            state.fontName = String(decoding: name.bytes, as: UTF8.self)
          }
          if let values = operands, values.count >= 2 { state.fontSize = values[1] }
        case "Tr":
          if let values = operands, let mode = values.first { state.textRenderingMode = Int(mode) }
        case "Ts":
          if let values = operands, let rise = values.first { state.textRise = rise }
        case "Tc":
          if let values = operands, let spacing = values.first { state.charSpacing = spacing }
        case "Tw":
          if let values = operands, let spacing = values.first { state.wordSpacing = spacing }
        case "Tz":
          if let values = operands, let scale = values.first { state.horizontalScale = scale }
        case "TL":
          if let values = operands, let leading = values.first { state.leading = leading }
        case "Td", "TD":
          if let values = operands, values.count == 2 {
            state.lineMatrix = translated(state.lineMatrix, dx: values[0], dy: values[1])
            state.textMatrix = state.lineMatrix
            if instruction.operatorName == "TD" { state.leading = -values[1] }
          }
        case "Tm":
          if let values = operands, values.count == 6 {
            state.textMatrix = values
            state.lineMatrix = values
          }
        case "T*":
          state.lineMatrix = translated(state.lineMatrix, dx: 0, dy: -state.leading)
          state.textMatrix = state.lineMatrix
        case "Tj", "'", "\"":
          recordText(state: state, instruction: instruction, index: index, graph: graph)
        case "TJ":
          recordText(state: state, instruction: instruction, index: index, graph: graph)
        case "Do":
          guard case .name(let name)? = instruction.operands.first?.value,
            case .dictionary(let xobjects)? = resources[PDFName("XObject")],
            let entry = xobjects[name]
          else {
            diagnostics.append(
              ContentTrace.Diagnostic(
                kind: .missingResource, instructionIndex: index,
                detail: "Do without a resolvable XObject"))
            continue
          }
          guard case .stream(let stream)? = resolve(entry, in: graph) else { continue }
          let resourceName = String(decoding: name.bytes, as: UTF8.self)
          let subtype = stream.dictionary[PDFName("Subtype")] == .name(PDFName("Form"))
            ? "Form" : "Image"
          let bounds = transformedUnitBounds(ctm: state.ctm, clip: state.clip, state: state)
          if draws.count < limits.maxDraws {
            draws.append(
              ContentTrace.DrawInstruction(
                kind: subtype == "Form" ? .form : .image, instructionIndex: index,
                bounds: bounds, fontName: nil, fontSize: nil, resourceName: resourceName,
                isInvisibleText: false, text: nil))
          }
          extendVisible(bounds)
          if subtype == "Form" {
            var nestedResources = resources
            if case .dictionary(let local)? = stream.dictionary[PDFName("Resources")] {
              nestedResources = merged(base: resources, overlay: local)
            }
            if case .array(let matrix)? = stream.dictionary[PDFName("Matrix")] {
              let values = matrix.compactMap { value -> Double? in
                switch value {
                case .integer(let number): return Double(number)
                case .real(let number): return number
                default: return nil
                }
              }
              if values.count == 6 {
                var nested = state
                nested.ctm = concatenate(state.ctm, values)
                state = nested
              }
            }
            if let formContent = try? ContentParser.instructions(in: [UInt8](stream.bytes))
            {
              var nested = Collector(limits: limits, draws: draws, marked: marked,
                diagnostics: diagnostics, visibleBounds: visibleBounds)
              try nested.run(
                instructions: formContent, resources: nestedResources, graph: graph,
                depth: depth + 1, initialCTM: state.ctm)
              draws = nested.draws
              marked = nested.marked
              diagnostics = nested.diagnostics
              visibleBounds = nested.visibleBounds
            }
          }
        case "re":
          if let values = operands, values.count == 4 {
            state.pendingPath.append(values)
            extendPendingPath(values)
            extendPendingPath([values[0] + values[2], values[1] + values[3]])
          }
        case "m", "l":
          if let values = operands, values.count == 2 {
            state.pendingPath.append(values)
            extendPendingPath(values)
          }
        case "c":
          if let values = operands, values.count == 6 {
            state.pendingPath.append([values[4], values[5]])
            extendPendingPath([values[4], values[5]])
          }
        case "S", "s", "f", "F", "f*", "B", "B*", "b", "b*":
          if !state.pendingPath.isEmpty, draws.count < limits.maxDraws {
            let bounds = transformedUnitBounds(ctm: state.ctm, clip: state.clip, state: state)
            draws.append(
              ContentTrace.DrawInstruction(
                kind: .path, instructionIndex: index, bounds: bounds, fontName: nil,
                fontSize: nil, resourceName: nil, isInvisibleText: false, text: nil))
            extendVisible(bounds)
          }
          state.pendingPath = []
          pendingBounds = nil
        case "W", "W*":
          // Clipping: keep the conservative intersection of the pending path.
          if let bounds = pendingBounds {
            let pageBounds = transformed(bounds, ctm: state.ctm)
            state.clip = state.clip.map { intersection($0, pageBounds) } ?? pageBounds
          }
        case "sh":
          let shadingBounds = transformedUnitBounds(
            ctm: state.ctm, clip: state.clip, state: state)
          if draws.count < limits.maxDraws {
            let bounds = shadingBounds
            draws.append(
              ContentTrace.DrawInstruction(
                kind: .shading, instructionIndex: index, bounds: bounds, fontName: nil,
                fontSize: nil, resourceName: nil, isInvisibleText: false, text: nil))
            extendVisible(bounds)
          }
        case "BDC", "BMC":
          var mcid: Int?
          var tag: String?
          var oc: String?
          for operand in instruction.operands {
            switch operand.value {
            case .name(let name):
              tag = String(decoding: name.bytes, as: UTF8.self)
            case .dictionary(let dictionary):
              if case .integer(let raw)? = dictionary[PDFName("MCID")] {
                mcid = Int(exactly: raw)
              }
              if case .name(let name)? = dictionary[PDFName("OC")] {
                oc = String(decoding: name.bytes, as: UTF8.self)
              }
            default:
              break
            }
          }
          markedStack.append((mcid, tag, index, oc))
        case "EMC":
          if let top = markedStack.popLast() {
            marked.append(
              ContentTrace.MarkedContentSpan(
                mcid: top.mcid, tag: top.tag, startInstruction: top.start,
                endInstruction: index, optionalContentName: top.oc))
          } else {
            diagnostics.append(
              ContentTrace.Diagnostic(
                kind: .unknownOperator, instructionIndex: index, detail: "EMC without BDC/BMC"))
          }
        case "BI":
          diagnostics.append(
            ContentTrace.Diagnostic(
              kind: .inlineImageOpaque, instructionIndex: index,
              detail: "Inline image payload kept opaque; following instructions are preserved"))
        default:
          break
        }
      }
      if !stack.isEmpty {
        diagnostics.append(
          ContentTrace.Diagnostic(
            kind: .unbalancedGraphicsStack, instructionIndex: instructions.count,
            detail: "\(stack.count) unclosed q entr\(stack.count == 1 ? "y" : "ies")"))
      }
      if inTextObject {
        diagnostics.append(
          ContentTrace.Diagnostic(
            kind: .unbalancedTextObject, instructionIndex: instructions.count,
            detail: "Text object was not closed with ET"))
      }
    }

    mutating func recordText(
      state: State, instruction: ContentInstruction, index: Int, graph: PDFGraph
    ) {
      var text: String?
      if case .string(let data)? = instruction.operands.first?.value {
        text = String(decoding: data, as: UTF8.self)
      }
      // The baseline is the text matrix origin transformed by the CTM.
      let origin = [
        state.textMatrix[4], state.textMatrix[5],
      ]
      let pageOrigin = transformed(origin, ctm: state.ctm)
      let height = state.fontSize * abs(state.ctm[3] == 0 ? 1 : state.ctm[3])
      let bounds = [
        pageOrigin[0], pageOrigin[1] - height * 0.25, pageOrigin[0] + height * 0.5,
        pageOrigin[1] + height * 0.75,
      ]
      let invisible = state.textRenderingMode == 3 || state.textRenderingMode == 7
      if draws.count < limits.maxDraws {
        draws.append(
          ContentTrace.DrawInstruction(
            kind: .text, instructionIndex: index, bounds: bounds, fontName: state.fontName,
            fontSize: state.fontSize, resourceName: nil, isInvisibleText: invisible, text: text))
      }
      extendVisible(bounds)
    }

    mutating func extendPendingPath(_ point: [Double]) {
      // Pending path bounds are tracked per instruction in a simple union.
      if pendingBounds == nil {
        pendingBounds = [point[0], point[1], point[0], point[1]]
      } else if point.count >= 2, var bounds = pendingBounds {
        bounds = [
          min(bounds[0], point[0]), min(bounds[1], point[1]), max(bounds[2], point[0]),
          max(bounds[3], point[1]),
        ]
        pendingBounds = bounds
      }
    }

    var pendingBounds: [Double]?

    mutating func extendVisible(_ bounds: [Double]) {
      visibleBounds = visibleBounds.map { intersection($0, bounds) } ?? bounds
    }

    func transformedUnitBounds(ctm: [Double], clip: [Double]?, state: State) -> [Double] {
      // The unit square transformed by the CTM is the conservative draw area.
      let bounds = transformed([0, 0, 1, 1], ctm: ctm)
      return clip.map { intersection($0, bounds) } ?? bounds
    }

    func numbers(_ operands: [ContentOperand]) -> [Double]? {
      var result: [Double] = []
      for operand in operands {
        switch operand.value {
        case .integer(let value): result.append(Double(value))
        case .real(let value): result.append(value)
        default: return nil
        }
      }
      return result
    }

    func resolve(_ value: PDFValue, in graph: PDFGraph) -> PDFValue? {
      if case .reference(let id) = value { return graph.objects[id] }
      return value
    }

    func concatenate(_ a: [Double], _ b: [Double]) -> [Double] {
      [
        a[0] * b[0] + a[2] * b[1], a[1] * b[0] + a[3] * b[1],
        a[0] * b[2] + a[2] * b[3], a[1] * b[2] + a[3] * b[3],
        a[0] * b[4] + a[2] * b[5] + a[4], a[1] * b[4] + a[3] * b[5] + a[5],
      ]
    }

    func translated(_ matrix: [Double], dx: Double, dy: Double) -> [Double] {
      concatenate(matrix, [1, 0, 0, 1, dx, dy])
    }

    func transformed(_ box: [Double], ctm: [Double]) -> [Double] {
      if box.count == 2 {
        let point = transformed([box[0], box[1], box[0], box[1]], ctm: ctm)
        return point
      }
      let corners = [
        [box[0], box[1]], [box[2], box[1]], [box[2], box[3]], [box[0], box[3]],
      ].map { point -> [Double] in
        [ctm[0] * point[0] + ctm[2] * point[1] + ctm[4],
         ctm[1] * point[0] + ctm[3] * point[1] + ctm[5]]
      }
      return [
        corners.map { $0[0] }.min() ?? 0, corners.map { $0[1] }.min() ?? 0,
        corners.map { $0[0] }.max() ?? 0, corners.map { $0[1] }.max() ?? 0,
      ]
    }

    func intersection(_ a: [Double], _ b: [Double]) -> [Double] {
      [
        max(a[0], b[0]), max(a[1], b[1]), min(a[2], b[2]), min(a[3], b[3]),
      ]
    }

    func merged(base: [PDFName: PDFValue], overlay: [PDFName: PDFValue]) -> [PDFName: PDFValue] {
      var result = base
      for (key, value) in overlay { result[key] = value }
      return result
    }
  }
}
