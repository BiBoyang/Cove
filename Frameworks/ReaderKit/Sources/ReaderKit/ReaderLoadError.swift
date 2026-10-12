import Foundation

/// Reader failures that are independent of the concrete page source.
public enum ReaderLoadError: Error, Sendable {
    /// The source returned bytes that do not decode as an image.
    case undecodable
    /// The source image exceeds the decode safety cap (see
    /// `ImagePipeline.maxSourcePixels`); distinct from `undecodable` so
    /// logs can tell a corrupt file apart from an oversized one.
    case imageTooLarge
}
