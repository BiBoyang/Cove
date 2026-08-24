/// Reader display modes: single-page manual paging (route A1) or the
/// continuous vertical strip. The default is chosen per content kind at
/// open time (comic → strip, directory → paged); the toggle applies to
/// the current session only and is never persisted.
enum ReaderMode: Sendable {
    case paged
    case strip
}
