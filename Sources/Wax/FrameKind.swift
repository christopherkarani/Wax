package enum FrameKind: Hashable, Sendable {
    case surrogate
    case handoff
    case photo(PhotoFrameKind)
    case video(VideoFrameKind)
    case other(String)

    init(rawKind: String?) {
        guard let rawKind else {
            self = .other("")
            return
        }
        if let photo = PhotoFrameKind(rawValue: rawKind) {
            self = .photo(photo)
        } else if let video = VideoFrameKind(rawValue: rawKind) {
            self = .video(video)
        } else {
            self = switch rawKind {
            case "surrogate": .surrogate
            case "handoff": .handoff
            default: .other(rawKind)
            }
        }
    }

    var storageValue: String? {
        switch self {
        case .surrogate:
            return "surrogate"
        case .handoff:
            return "handoff"
        case .photo(let kind):
            return kind.rawValue
        case .video(let kind):
            return kind.rawValue
        case .other(let raw):
            return raw.isEmpty ? nil : raw
        }
    }
}
