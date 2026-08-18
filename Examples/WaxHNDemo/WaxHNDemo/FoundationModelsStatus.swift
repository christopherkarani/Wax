#if canImport(FoundationModels)
import Wax

enum FoundationModelsStatus {
    @available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
    static func publishedString(_ availability: WaxFoundationModelsAvailability) -> String {
        switch availability {
        case .available:
            "available"
        case .unavailable(let reason):
            reason
        }
    }
}
#endif
