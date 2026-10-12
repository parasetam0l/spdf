import Foundation

/// P04-012: how an object reference resolves. Parse callers that can proceed
/// without the object match on this instead of catching one undifferentiated
/// error; the throwing parser maps each case back to its established
/// `PDFError` kind and message.
public enum ObjectResolution: Sendable, Equatable {
  /// The object loaded and (when applicable) decrypted.
  case resolved(PDFValue)
  /// No cross-reference entry names this object.
  case missing
  /// The cross-reference marks this object free.
  case free
  /// An entry exists but the object bytes do not parse.
  case malformed(String)
  /// The object is recognized but the profile does not implement it.
  case unsupported(String)
  /// Loading tripped a resource bound (nesting, size, count).
  case limit(String)
}

/// P04-015: cycle-aware graph traversal. Every reachable-object walk in the
/// codebase must terminate on cyclic graphs; this is the shared utility so
/// individual call sites stop reimplementing visited-sets.
public enum PDFGraphTraversal {
  /// Depth-first object IDs reachable from `roots`, each reported once in
  /// visit order, plus one entry per back edge found: the cycle as the path
  /// from the ancestor back to itself (for example `[A, B, A]`).
  public static func reachable(
    from roots: [PDFObjectID], in graph: PDFGraph
  ) -> (order: [PDFObjectID], cycles: [[PDFObjectID]]) {
    var order: [PDFObjectID] = []
    var cycles: [[PDFObjectID]] = []
    // finished holds fully explored IDs; stack holds the current DFS path.
    var finished = Set<PDFObjectID>()
    var stack: [PDFObjectID] = []
    var onStack = Set<PDFObjectID>()

    func children(of id: PDFObjectID) -> [PDFObjectID] {
      guard case .dictionary(let dictionary)? = graph.objects[id] else {
        if case .stream(let stream)? = graph.objects[id] {
          return references(in: .dictionary(stream.dictionary))
        }
        if case .array(let values)? = graph.objects[id] {
          return values.flatMap { references(in: $0) }
        }
        return []
      }
      return references(in: .dictionary(dictionary))
    }

    func references(in value: PDFValue) -> [PDFObjectID] {
      switch value {
      case .reference(let id):
        return [id]
      case .array(let values):
        return values.flatMap { references(in: $0) }
      case .dictionary(let dictionary):
        return dictionary.values.flatMap { references(in: $0) }
      case .stream(let stream):
        return references(in: .dictionary(stream.dictionary))
      default:
        return []
      }
    }

    func visit(_ id: PDFObjectID) {
      if finished.contains(id) { return }
      if onStack.contains(id) {
        if let start = stack.firstIndex(of: id) {
          cycles.append(Array(stack[start...]) + [id])
        }
        return
      }
      stack.append(id)
      onStack.insert(id)
      order.append(id)
      for child in children(of: id) {
        visit(child)
      }
      stack.removeLast()
      onStack.remove(id)
      finished.insert(id)
    }

    for root in roots {
      visit(root)
    }
    return (order, cycles)
  }
}

/// P04-024: byte-comparison utilities for untouched-resource verification.
/// Callers proving unrelated edits preserve bytes use these instead of
/// reimplementing prefix scans.
public enum PDFBytes {
  /// The first offset where the inputs differ, or nil when they are equal.
  /// A length difference counts as a difference at the shorter length.
  public static func firstDifference(between left: [UInt8], and right: [UInt8]) -> Int? {
    let common = min(left.count, right.count)
    for index in 0..<common {
      if left[index] != right[index] { return index }
    }
    return left.count == right.count ? nil : common
  }

  public static func firstDifference(between left: Data, and right: Data) -> Int? {
    if left == right { return nil }
    return firstDifference(
      between: [UInt8](left), and: [UInt8](right))
  }

  /// The length of the shared prefix, for reporting how much survived.
  public static func commonPrefixLength(between left: [UInt8], and right: [UInt8]) -> Int {
    let common = min(left.count, right.count)
    var length = 0
    while length < common, left[length] == right[length] {
      length += 1
    }
    return length
  }
}
