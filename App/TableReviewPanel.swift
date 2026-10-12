import PDFEditing
import SwiftUI

/// P36-009: a native review grid for detected tables. Cells are editable,
/// rows/columns can be deleted, and each table can be accepted or rejected
/// before exporting. Rendering is bounded to 400 cells per table.
struct TableReviewPanel: View {
  @ObservedObject var model: TableReviewModel
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
        Button("Export CSV…", action: onExportCSV)
        Button("Export XLSX…", action: onExportXLSX)
        Button("Close", action: onClose)
      }
    }
    .padding(14)
    .frame(minWidth: 600, minHeight: 420)
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
        if let limitations = model.selected?.table.limitations, !limitations.isEmpty {
          Text(limitations.joined(separator: " "))
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
    } else {
      Rectangle()
        .fill(Color.secondary.opacity(0.08))
        .frame(width: 130, height: 22)
    }
  }
}
