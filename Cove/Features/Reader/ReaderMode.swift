/// Reader display modes: single-page manual paging (route A1) or the
/// continuous vertical strip. The default is chosen per content kind at
/// open time (comic → strip, directory → paged) unless the user's saved
/// preference for that kind overrides it (SettingsService persists the
/// raw value; the mapping lives at the coordinator).
enum ReaderMode: String, Sendable {
    case paged
    case strip
}
