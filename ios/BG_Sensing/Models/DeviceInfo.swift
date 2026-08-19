import Foundation

enum DeviceInfo {
    /// Raw hardware identifier (e.g. `"iPhone15,2"` for an iPhone 14 Pro), read via
    /// `uname()`. Stored as-is rather than mapped to a marketing name — the raw
    /// identifier is unambiguous and can be cross-referenced against Apple's public
    /// device ID lists, whereas a hand-maintained name table would silently go stale.
    static var hardwareIdentifier: String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let mirror = Mirror(reflecting: systemInfo.machine)
        return mirror.children.reduce(into: "") { result, element in
            guard let value = element.value as? Int8, value != 0 else { return }
            result += String(UnicodeScalar(UInt8(value)))
        }
    }
}
