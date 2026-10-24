import Foundation
import PDFCore

/// PAG-09: editable document information dictionary fields. The command
/// updates `/Info` only; XMP remains untouched and is reported separately by
/// the inventory.
public struct DocumentMetadata: Sendable, Equatable {
  public var title: String?
  public var author: String?
  public var subject: String?
  public var keywords: String?
  public var creator: String?
  public var producer: String?

  public init(
    title: String? = nil, author: String? = nil, subject: String? = nil,
    keywords: String? = nil, creator: String? = nil, producer: String? = nil
  ) {
    self.title = title
    self.author = author
    self.subject = subject
    self.keywords = keywords
    self.creator = creator
    self.producer = producer
  }
}

public struct SetDocumentMetadataCommand: PDFEditCommand, Equatable, Sendable {
  public let metadata: DocumentMetadata

  public init(metadata: DocumentMetadata) {
    self.metadata = metadata
  }

  public var name: String { "Set Document Metadata" }
  public func affectedPageIDs(in graph: PDFGraph) -> [PDFObjectID] { [] }

  public func validate(in graph: PDFGraph) throws {
    let values = [
      metadata.title, metadata.author, metadata.subject, metadata.keywords,
      metadata.creator, metadata.producer,
    ]
    for value in values {
      guard let value else { continue }
      guard value.utf8.count <= 16_384 else {
        throw PDFError(.limitExceeded, "A metadata value exceeds the size limit")
      }
    }
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    var graph = graph
    var info: [PDFName: PDFValue]
    var infoID: PDFObjectID?
    if case .reference(let id)? = graph.trailer[PDFName("Info")],
      case .dictionary(let existing)? = graph.objects[id]
    {
      info = existing
      infoID = id
    } else if case .dictionary(let existing)? = graph.trailer[PDFName("Info")] {
      info = existing
    } else {
      info = [:]
    }
    func set(_ key: String, _ value: String?) {
      let name = PDFName(key)
      guard let value, !value.isEmpty else {
        info.removeValue(forKey: name)
        return
      }
      info[name] = .string(AnnotationText.encode(value))
    }
    set("Title", metadata.title)
    set("Author", metadata.author)
    set("Subject", metadata.subject)
    set("Keywords", metadata.keywords)
    set("Creator", metadata.creator)
    set("Producer", metadata.producer)
    if info.isEmpty {
      graph.trailer[PDFName("Info")] = nil
      if let infoID { graph.objects[infoID] = nil }
      return graph
    }
    if let infoID {
      graph.objects[infoID] = .dictionary(info)
      graph.trailer[PDFName("Info")] = .reference(infoID)
    } else {
      let newID = PDFObjectID((graph.objects.keys.map(\.number).max() ?? 0) + 1)
      graph.objects[newID] = .dictionary(info)
      graph.trailer[PDFName("Info")] = .reference(newID)
      graph.trailer[PDFName("Size")] = .integer(Int64(newID.number + 1))
    }
    return graph
  }
}
