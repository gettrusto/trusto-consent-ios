import Foundation

/// O que o SDK diz do aparelho: sistema e modelo genérico. Nunca identificador de publicidade,
/// `identifierForVendor` ou outro identificador do aparelho.
struct DeviceInfo: Equatable, Sendable {
    let os: String
    let device: String?

    static let maxOS = 40
    static let maxDevice = 60

    static func current() -> DeviceInfo {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        var number = "\(version.majorVersion).\(version.minorVersion)"
        if version.patchVersion > 0 { number += ".\(version.patchVersion)" }
        #if os(iOS)
        let name = "iOS"
        let model = sysctlString("hw.machine")
        #elseif os(macOS)
        let name = "macOS"
        let model = sysctlString("hw.model")
        #elseif os(tvOS)
        let name = "tvOS"
        let model = sysctlString("hw.machine")
        #else
        let name = "Apple"
        let model: String? = nil
        #endif
        return make(os: "\(name) \(number)", device: model)
    }

    /// Ajusta ao que o coletor aceita: só letras, números, espaço e `._()-/,+`, com teto.
    static func make(os: String, device: String?) -> DeviceInfo {
        DeviceInfo(os: sanitize(os, max: maxOS) ?? "iOS", device: device.flatMap { sanitize($0, max: maxDevice) })
    }

    static func sanitize(_ raw: String, max: Int) -> String? {
        let allowed = CharacterSet.letters.union(.decimalDigits).union(CharacterSet(charactersIn: " ._()-/,+"))
        var scalars = String.UnicodeScalarView()
        for scalar in raw.unicodeScalars {
            scalars.append(allowed.contains(scalar) ? scalar : " ")
        }
        let collapsed = String(scalars)
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
        let truncated = String(collapsed.prefix(max)).trimmingCharacters(in: .whitespaces)
        return truncated.isEmpty ? nil : truncated
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}
