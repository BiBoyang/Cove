import Foundation

/// Reader failures that are independent of the concrete page source.
public enum ReaderLoadError: Error, Sendable {
    /// The source returned bytes that do not decode as an image.
    case undecodable
}
