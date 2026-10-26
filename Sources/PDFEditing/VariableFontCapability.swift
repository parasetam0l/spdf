import Foundation
import PDFCore

/// FNT-07: one declared axis of a variable font, decoded from the fvar table.
public struct VariableFontAxis: Sendable, Equatable {
  public let tag: String
  public let minimum: Double
  public let defaultValue: Double
  public let maximum: Double
  public let flags: Int
  public let nameID: Int

  public init(
    tag: String, minimum: Double, defaultValue: Double, maximum: Double,
    flags: Int, nameID: Int
  ) {
    self.tag = tag
    self.minimum = minimum
    self.defaultValue = defaultValue
    self.maximum = maximum
    self.flags = flags
    self.nameID = nameID
  }
}

/// FNT-07: one named instance of a variable font with its full axis
/// coordinate tuple.
public struct VariableFontInstance: Sendable, Equatable {
  public let subfamilyNameID: Int
  public let flags: Int
  /// Axis tag to coordinate value; one entry per declared axis.
  public let coordinates: [String: Double]
  public let postScriptNameID: Int?

  public init(
    subfamilyNameID: Int, flags: Int, coordinates: [String: Double],
    postScriptNameID: Int?
  ) {
    self.subfamilyNameID = subfamilyNameID
    self.flags = flags
    self.coordinates = coordinates
    self.postScriptNameID = postScriptNameID
  }

  /// True when every coordinate equals the axis default.
  public func isDefaultInstance(axes: [VariableFontAxis]) -> Bool {
    axes.allSatisfy { axis in
      guard let value = coordinates[axis.tag] else { return false }
      return abs(value - axis.defaultValue) <= 1e-6
    }
  }
}

/// FNT-07: which variable-font profile the PDF writer can represent faithfully.
public enum VariableFontEmbeddingProfile: Sendable, Equatable {
  /// The writer embeds the base glyf/hmtx tables, which are drawn at the
  /// declared default axis values; the preview must use the same values.
  case staticDefaultInstance
  /// The program cannot be embedded faithfully; the reason is explicit.
  case unsupported(String)
}

/// FNT-07: the explicit capability result for one font program. It never
/// silently treats a non-default instance as the base outlines.
public struct VariableFontCapability: Sendable, Equatable {
  public let isVariableFont: Bool
  public let axes: [VariableFontAxis]
  public let namedInstances: [VariableFontInstance]
  public let profile: VariableFontEmbeddingProfile
  /// True when the program declares CFF2 variable outlines.
  public let isCFF2: Bool

  public init(
    isVariableFont: Bool, axes: [VariableFontAxis],
    namedInstances: [VariableFontInstance], profile: VariableFontEmbeddingProfile,
    isCFF2: Bool
  ) {
    self.isVariableFont = isVariableFont
    self.axes = axes
    self.namedInstances = namedInstances
    self.profile = profile
    self.isCFF2 = isCFF2
  }

  /// Axis tag to declared default value, the only coordinates the inline
  /// subset writer can embed.
  public var defaultInstanceCoordinates: [String: Double] {
    Dictionary(uniqueKeysWithValues: axes.map { ($0.tag, $0.defaultValue) })
  }

  /// Named instances whose coordinates coincide with the axis defaults.
  public var defaultInstanceNameIDs: [Int] {
    namedInstances.filter { $0.isDefaultInstance(axes: axes) }.map(\.subfamilyNameID)
  }

  /// Non-default named instances in declaration order.
  public var nonDefaultInstances: [VariableFontInstance] {
    namedInstances.filter { !$0.isDefaultInstance(axes: axes) }
  }

  /// Whether the exact coordinates are the embeddable default instance.
  public func matchesDefaultInstance(_ coordinates: [String: Double]) -> Bool {
    axes.allSatisfy { axis in
      guard let value = coordinates[axis.tag] else { return false }
      return abs(value - axis.defaultValue) <= 1e-6
    }
  }

  /// FNT-07: explicit per-selection result. Non-default named instances are
  /// refused with a stable reason rather than approximated.
  public func capability(
    for selection: VariableFontInstanceSelection
  ) -> VariableFontSelectionCapability {
    switch selection {
    case .defaultInstance:
      guard case .staticDefaultInstance = profile else {
        if case .unsupported(let reason) = profile { return .unsupported(reason) }
        return .unsupported("This font program cannot be embedded as a static default instance")
      }
      guard !isCFF2 else {
        return .unsupported("CFF2 variable outlines are not supported by the inline subset writer")
      }
      return .supportedDefaultInstance
    case .named(let index):
      guard namedInstances.indices.contains(index) else {
        return .unsupported("The named instance index is outside the font's fvar instances")
      }
      let instance = namedInstances[index]
      guard instance.isDefaultInstance(axes: axes) else {
        return .unsupported(Self.nonDefaultInstanceReason)
      }
      return capability(for: .defaultInstance)
    case .coordinates(let coordinates):
      guard matchesDefaultInstance(coordinates) else {
        return .unsupported(Self.nonDefaultInstanceReason)
      }
      return capability(for: .defaultInstance)
    }
  }

  public static let nonDefaultInstanceReason =
    "The PDF subset writer embeds the font's base glyf/hmtx tables, which are drawn at the declared default axis values. A non-default variable instance cannot be represented faithfully; extract a static instance first."
}

/// FNT-07: a requested variable-font selection.
public enum VariableFontInstanceSelection: Sendable, Equatable {
  case defaultInstance
  case named(index: Int)
  case coordinates([String: Double])
}

public enum VariableFontSelectionCapability: Sendable, Equatable {
  case supportedDefaultInstance
  case unsupported(String)

  public var isSupported: Bool {
    if case .supportedDefaultInstance = self { return true }
    return false
  }

  public var reason: String? {
    if case .unsupported(let reason) = self { return reason }
    return nil
  }
}

/// FNT-07: bounded fvar parser and embedding-capability inspector. Every count,
/// offset and coordinate is range-checked; malformed or unsupported programs
/// return an explicit capability result instead of approximating.
public enum VariableFontCapabilityInspector {
  public struct Limits: Sendable, Equatable {
    public var maximumAxes: Int
    public var maximumInstances: Int
    public init(maximumAxes: Int = 32, maximumInstances: Int = 256) {
      self.maximumAxes = maximumAxes
      self.maximumInstances = maximumInstances
    }
  }

  private struct Fixed16_16 {
    let value: Double
  }

  public static func inspect(
    program: Data, limits: Limits = .init()
  ) -> VariableFontCapability {
    let inspector: TrueTypeInspector
    do {
      inspector = try TrueTypeInspector.inspect(program, requireUnicodeMap: false)
    } catch {
      return VariableFontCapability(
        isVariableFont: false, axes: [], namedInstances: [],
        profile: .unsupported(
          "The font program is malformed or unsupported; no variable profile can be declared."),
        isCFF2: false)
    }
    let isCFF2 = inspector.tables["CFF2"] != nil
    guard isCFF2 || inspector.tables["fvar"] != nil else {
      return VariableFontCapability(
        isVariableFont: false, axes: [], namedInstances: [],
        profile: .staticDefaultInstance, isCFF2: false)
    }
    if isCFF2 {
      return VariableFontCapability(
        isVariableFont: true, axes: [], namedInstances: [],
        profile: .unsupported(
          "CFF2 variable outlines are not supported by the inline subset writer."),
        isCFF2: true)
    }
    guard let fvar = inspector.tables["fvar"] else {
      return VariableFontCapability(
        isVariableFont: false, axes: [], namedInstances: [],
        profile: .unsupported("The font declares no fvar table."), isCFF2: false)
    }
    let bytes = [UInt8](program)
    let end = fvar.offset + fvar.length
    guard fvar.offset >= 0, end <= bytes.count else {
      return unsupported("The font's fvar table runs past the program.")
    }
    do {
      let parsed = try parseFvar(
        bytes: bytes, start: fvar.offset, end: end, limits: limits)
      return VariableFontCapability(
        isVariableFont: true, axes: parsed.axes, namedInstances: parsed.instances,
        profile: .staticDefaultInstance, isCFF2: false)
    } catch let error as VariableFontParseError {
      return unsupported(error.message)
    } catch {
      return unsupported("The font's fvar table could not be read.")
    }
  }

  private static func unsupported(_ message: String) -> VariableFontCapability {
    VariableFontCapability(
      isVariableFont: true, axes: [], namedInstances: [],
      profile: .unsupported(message), isCFF2: false)
  }

  private struct ParsedFvar {
    let axes: [VariableFontAxis]
    let instances: [VariableFontInstance]
  }

  private struct VariableFontParseError: Error {
    let message: String
  }

  private static func parseFvar(
    bytes: [UInt8], start: Int, end: Int, limits: Limits
  ) throws -> ParsedFvar {
    func require(_ condition: Bool, _ message: String) throws {
      guard condition else { throw VariableFontParseError(message: message) }
    }
    func u16(_ offset: Int) throws -> Int {
      guard offset >= start, offset + 2 <= end else {
        throw VariableFontParseError(message: "The font's fvar table is truncated.")
      }
      return Int(bytes[offset]) * 256 + Int(bytes[offset + 1])
    }
    func fixed(_ offset: Int) throws -> Double {
      guard offset >= start, offset + 4 <= end else {
        throw VariableFontParseError(message: "A font variation value is truncated.")
      }
      var raw: UInt32 = 0
      for index in 0..<4 {
        raw = raw << 8 | UInt32(bytes[offset + index])
      }
      return Double(Int32(bitPattern: raw)) / 65_536
    }

    try require(try u16(start) == 1, "The font's fvar major version is unsupported.")
    let axisArrayOffset = try u16(start + 4)
    let axisCount = try u16(start + 8)
    let axisSize = try u16(start + 10)
    let instanceCount = try u16(start + 12)
    let instanceSize = try u16(start + 14)
    try require(axisCount > 0, "The font declares no variation axes.")
    try require(axisCount <= limits.maximumAxes, "The font declares too many variation axes.")
    try require(instanceCount <= limits.maximumInstances, "The font declares too many named instances.")
    try require(axisSize >= 20, "The font's fvar axis records are too small.")
    try require(instanceSize >= 4 + axisCount * 4, "The font's fvar instance records are too small.")

    let axesStart = start + axisArrayOffset
    try require(axesStart >= start, "The font's fvar axis array offset is invalid.")
    var axes: [VariableFontAxis] = []
    axes.reserveCapacity(axisCount)
    for index in 0..<axisCount {
      let base = axesStart + index * axisSize
      try require(base >= start && base + 20 <= end,
        "A font variation axis record runs past the fvar table.")
      let tagBytes = Array(bytes[base..<(base + 4)])
      guard tagBytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }),
        let tag = String(bytes: tagBytes, encoding: .ascii)
      else {
        throw VariableFontParseError(message: "A font variation axis tag is not printable ASCII.")
      }
      let minimum = try fixed(base + 4)
      let defaultValue = try fixed(base + 8)
      let maximum = try fixed(base + 12)
      try require(minimum.isFinite && defaultValue.isFinite && maximum.isFinite,
        "A font variation axis has non-finite bounds.")
      try require(minimum <= defaultValue, "A font variation axis minimum exceeds its default.")
      try require(defaultValue <= maximum, "A font variation axis default exceeds its maximum.")
      let flags = try u16(base + 16)
      let nameID = try u16(base + 18)
      axes.append(
        VariableFontAxis(
          tag: tag, minimum: minimum, defaultValue: defaultValue, maximum: maximum,
          flags: flags, nameID: nameID))
    }
    let instancesStart = axesStart + axisCount * axisSize
    var instances: [VariableFontInstance] = []
    instances.reserveCapacity(instanceCount)
    for index in 0..<instanceCount {
      let base = instancesStart + index * instanceSize
      try require(base >= start && base + 4 <= end,
        "A font named-instance record runs past the fvar table.")
      let nameID = try u16(base)
      let flags = try u16(base + 2)
      var coordinates: [String: Double] = [:]
      for axisIndex in 0..<axisCount {
        let value = try fixed(base + 4 + axisIndex * 4)
        let axis = axes[axisIndex]
        try require(value.isFinite, "A font named instance has a non-finite coordinate.")
        try require(value >= axis.minimum - 1e-6 && value <= axis.maximum + 1e-6,
          "A font named instance coordinate is outside its axis range.")
        coordinates[axis.tag] = value
      }
      var postScriptNameID: Int?
      if instanceSize >= 4 + axisCount * 4 + 2, base + instanceSize <= end {
        postScriptNameID = try u16(base + 4 + axisCount * 4)
        if postScriptNameID == 0xFFFF { postScriptNameID = nil }
      }
      instances.append(
        VariableFontInstance(
          subfamilyNameID: nameID, flags: flags, coordinates: coordinates,
          postScriptNameID: postScriptNameID))
    }
    return ParsedFvar(axes: axes, instances: instances)
  }
}
