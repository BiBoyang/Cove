import Foundation

/// One entry in a directory listing.
public struct ContentItem: Sendable, Hashable {
    /// Coarse file classification derived from the file extension.
    public enum FileType: String, Sendable, CaseIterable {
        case video
        case image
        case pdf
        case text
        case other
    }

    public let name: String
    /// Share-relative absolute path (starts with `/`).
    public let path: String
    public let isDirectory: Bool
    /// File size in bytes; `0` for directories.
    public let size: Int64
    public let modifiedDate: Date?

    public init(name: String, path: String, isDirectory: Bool, size: Int64, modifiedDate: Date?) {
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
        self.size = size
        self.modifiedDate = modifiedDate
    }

    /// Classification by file extension. `nil` for directories.
    public var fileType: FileType? {
        guard !isDirectory else { return nil }
        return FileType(classifying: name)
    }
}

extension ContentItem.FileType {
    /// Derives the type from a file name's extension (case-insensitive).
    init(classifying name: String) {
        switch (name as NSString).pathExtension.lowercased() {
        case "mp4", "mkv", "avi", "mov", "wmv", "flv", "webm", "m4v",
             "ts", "m2ts", "mpg", "mpeg", "3gp", "rmvb":
            self = .video
        case "jpg", "jpeg", "png", "gif", "bmp", "webp", "heic", "heif",
             "tiff", "tif", "avif":
            self = .image
        case "pdf":
            self = .pdf
        case "txt", "md", "log", "nfo", "srt", "ass":
            self = .text
        default:
            self = .other
        }
    }
}
