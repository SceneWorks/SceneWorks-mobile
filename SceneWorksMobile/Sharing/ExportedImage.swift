import CoreTransferable
import Foundation
import ImageIO
import UniformTypeIdentifiers
import SwiftUI

/// The generated result expressed as a PNG `Transferable`, so the screen can
/// hand it to a `ShareLink`. Encoding is lossless: sharing hands over exactly
/// the generated pixels.
struct ExportedImage: Transferable {
    let image: GeneratedImage
    let seed: UInt64

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .png) { exported in
            try ImageExporter().pngData(image: exported.image)
        }
        .suggestedFileName { exported in
            ImageExporter.fileName(seed: exported.seed)
        }
    }
}
