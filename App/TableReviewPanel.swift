import PDFEditing
import SwiftUI

/// P36-009 + EXP-02: a native review grid for detected tables. Cells are
/// editable; rows/columns can be deleted; the reviewed header row count,
/// reviewed boundaries (insert/split) and a multipage continuation can be
/// applied before exporting reviewed CSV/XLSX with its report sidecar.
/// Rendering is bounded to 400 cells per table.
struct TableReviewPanel: View {
  @ObservedObject var model: TableReviewModel
  /// Kept for compatibility with the existing document window factory; the
  /// EXP-02 buttons export the reviewed tables directly through the model so
  /// headers, boundaries and continuation are always included.
  var onExportCSV: () -> Void
  var onExportXLSX: () -> Void
  var onClose: () -> Void

  private static let maxRenderedCells = 400

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 12) {
        Text("Tables").font(.headline)
        if model.reviews.count > 1 {
          Picker("", selection: $model.selectedIndex) {
            ForEach(model.reviews.indices, id: \.self) { index in
              Text("Table \(index + 1)").tag(index)
            }
          }
          .labelsHidden()
          .frame(width: 140)
        }
        Text(model.statusText).font(.caption).foregroundStyle(.secondary)
        Spacer()
      }
      if let table = model.selectedTable {
        HStack(spacing: 12) {
          Stepper(
            "Header rows: \(model.selectedHeaderRowCount)",
            value: Binding(
              get: { model.selectedHeaderRowCount },
              set: { model.setHeaderRowCount($0) }),
            in: 0...max(table.rowCount, 0))
          Button("Merge continuation…") { model.mergeContinuation() }
            .disabled(!model.canMergeContinuation)
            .help(
              "Fold the next reviewed table with the same column count into this one as a "
                + "continued page.")
          Spacer()
        }
        .font(.caption)
        grid(for: table)
      } else {
        Text("This detection was rejected; choose another table or close the panel.")
          .foregroundStyle(.secondary)
      }
      if let message = model.message {
        Text(message).font(.caption).foregroundStyle(.red)
      }
      HStack {
        Button("Accept") { model.accept() }
        Button("Reject") { model.reject() }
        Spacer()
        Button("Export Reviewed CSV…") { model.exportReviewed(.csv) }
        Button("Export Reviewed XLSX…") { model.exportReviewed(.xlsx) }
        Button("Close", action: onClose)
      }
    }
    .padding(14)
    .frame(minWidth: 640, minHeight: 460)
  }

  @ViewBuilder
  private func grid(for table: ExtractedTable) -> some View {
    let columnCount = max(table.columnCount, 1)
    let visibleRows = min(table.rowCount, max(1, Self.maxRenderedCells / columnCount))
    let truncated = visibleRows < table.rowCount
    VStack(alignment: .leading, spacing: 6) {
      ScrollView([.horizontal, .vertical]) {
        Grid(alignment: .leading, horizontalSpacing: 4, verticalSpacing: 4) {
          ForEach(0..<visibleRows, id: \.self) { row in
            GridRow {
              Text("\(row + 1)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 22, alignment: .trailing)
              ForEach(0..<columnCount, id: \.self) { column in
                cellView(table: table, row: row, column: column)
              }
            }
          }
        }
        .padding(4)
      }
      .frame(maxHeight: 260)
      HStack {
        if truncated {
          Text("Showing the first \(visibleRows) of \(table.rowCount) rows.")
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        if !table.limitations.isEmpty {
          Text(table.limitations.joined(separator: " "))
            .font(.caption2)
            .foregroundStyle(.orange)
        }
      }
    }
  }

  @ViewBuilder
  private func cellView(table: ExtractedTable, row: Int, column: Int) -> some View {
    if let cell = table.cell(row: row, column: column) {
      let label = cell.columnSpan > 1 || cell.rowSpan > 1
        ? "\(cell.text)  [\(cell.rowSpan)×\(cell.columnSpan)]" : cell.text
      TextField(
        "", text: Binding(
          get: { cell.text },
          set: { model.setText(row: row, column: column, text: $0) })
      )
      .textFieldStyle(.roundedBorder)
      .frame(width: cell.columnSpan > 1 ? 200 : 130)
      .help("\(label) · \(cell.provenance.rawValue) · confidence \(String(format: "%.2f", cell.confidence))")
      .contextMenu {
        if cell.rowSpan > 1 || cell.columnSpan > 1 {
          Button("Split merged cell") { model.splitCell(row: row, column: column) }
        }
        Button("Insert reviewed row after") { model.insertRow(after: row) }
        Button("Insert reviewed column after") { model.insertColumn(after: column) }
        Divider()
        Button("Delete row") { model.deleteRow(row) }
        Button("Delete column") { model.deleteColumn(column) }
      }
    } else {
      Rectangle()
        .fill(Color.secondary.opacity(0.08))
        .frame(width: 130, height: 22)
        .contextMenu {
          Button("Insert reviewed row after") { model.insertRow(after: row) }
          Button("Insert reviewed column after") { model.insertColumn(after: column) }
        }
    }
  }
}
