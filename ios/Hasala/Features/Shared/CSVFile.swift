import CoreTransferable
import Foundation
import HasalaModels
import UniformTypeIdentifiers

struct CSVFile: Transferable {
  let rows: [ExportRow]
  let name: String

  static var transferRepresentation: some TransferRepresentation {
    DataRepresentation(exportedContentType: .commaSeparatedText) { file in
      Data(CSVExport.csv(file.rows).utf8)
    }
    .suggestedFileName { $0.name }
  }
}
