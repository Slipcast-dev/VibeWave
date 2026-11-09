import CryptoKit
import Foundation

/// Версия вида «2.0.0». Недостающие части равны нулю, суффиксы после «-» и «+» не учитываются.
public struct AppVersion: Comparable, CustomStringConvertible, Sendable {
    public let parts: [Int]

    public init?(_ string: String) {
        let core = string.trimmingCharacters(in: .whitespaces)
            .drop(while: { $0 == "v" || $0 == "V" })
            .split(whereSeparator: { $0 == "-" || $0 == "+" }).first.map(String.init) ?? ""
        let numbers = core.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !numbers.isEmpty, numbers.count <= 4, numbers.allSatisfy({ ($0 ?? -1) >= 0 }) else { return nil }
        parts = numbers.map { $0! }
    }

    public var description: String { parts.map(String.init).joined(separator: ".") }

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        for index in 0..<max(lhs.parts.count, rhs.parts.count) {
            let left = index < lhs.parts.count ? lhs.parts[index] : 0
            let right = index < rhs.parts.count ? rhs.parts[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    public static func == (lhs: AppVersion, rhs: AppVersion) -> Bool { !(lhs < rhs) && !(rhs < lhs) }
}

/// Описание обновления `update.json`, которое публикуется в каждом релизе.
/// Подпись Ed25519 ставится на байты архива: подменённый архив или чужая сборка не пройдут проверку.
public struct UpdateManifest: Codable, Equatable, Sendable {
    public var version: String
    /// Адрес ZIP-архива с VibeWave.app.
    public var url: URL
    /// SHA-256 архива в шестнадцатеричном виде.
    public var sha256: String
    /// Подпись архива Ed25519 в Base64.
    public var signature: String
    public var minimumSystemVersion: String
    /// Короткое описание изменений по кодам языков («ru», «en»).
    public var notes: [String: String]

    public init(version: String, url: URL, sha256: String, signature: String,
                minimumSystemVersion: String = "13.0", notes: [String: String] = [:]) {
        self.version = version
        self.url = url
        self.sha256 = sha256
        self.signature = signature
        self.minimumSystemVersion = minimumSystemVersion
        self.notes = notes
    }

    private enum CodingKeys: String, CodingKey { case version, url, sha256, signature, minimumSystemVersion, notes }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(String.self, forKey: .version)
        url = try container.decode(URL.self, forKey: .url)
        sha256 = try container.decode(String.self, forKey: .sha256)
        signature = try container.decode(String.self, forKey: .signature)
        minimumSystemVersion = try container.decodeIfPresent(String.self, forKey: .minimumSystemVersion) ?? "13.0"
        notes = try container.decodeIfPresent([String: String].self, forKey: .notes) ?? [:]
    }

    /// Обновление предлагается, только если версия новее текущей, система подходит,
    /// а архив скачивается по HTTPS (или из локального файла в проверках).
    public func isOffered(currentVersion: String, systemVersion: OperatingSystemVersion) -> Bool {
        guard let offered = AppVersion(version), let current = AppVersion(currentVersion), current < offered,
              let minimum = AppVersion(minimumSystemVersion),
              url.scheme == "https" || url.isFileURL else { return false }
        let system = AppVersion("\(systemVersion.majorVersion).\(systemVersion.minorVersion).\(systemVersion.patchVersion)")!
        return !(system < minimum)
    }

    public func notes(for language: AppLanguage) -> String? {
        notes[language.rawValue] ?? notes["en"]
    }
}

/// Подпись и проверка архивов обновления (Ed25519, CryptoKit).
public enum UpdateSignature {
    public enum Failure: Error, Equatable {
        case badPublicKey, badSignature, checksumMismatch, signatureMismatch
    }

    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Проверяет контрольную сумму и подпись архива. Ключ — 32 байта открытого ключа в Base64.
    public static func verify(_ archive: Data, manifest: UpdateManifest, publicKey: String) throws {
        guard sha256Hex(archive) == manifest.sha256.lowercased() else { throw Failure.checksumMismatch }
        guard let keyData = Data(base64Encoded: publicKey),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData) else { throw Failure.badPublicKey }
        guard let signature = Data(base64Encoded: manifest.signature) else { throw Failure.badSignature }
        guard key.isValidSignature(signature, for: archive) else { throw Failure.signatureMismatch }
    }

    /// Подпись архива закрытым ключом (32 байта в Base64). Используется скриптом выпуска и проверками.
    public static func sign(_ archive: Data, privateKey: String) throws -> String {
        guard let keyData = Data(base64Encoded: privateKey),
              let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: keyData) else { throw Failure.badPublicKey }
        return try key.signature(for: archive).base64EncodedString()
    }

    /// Новая пара ключей: (закрытый, открытый) в Base64.
    public static func generateKeyPair() -> (privateKey: String, publicKey: String) {
        let key = Curve25519.Signing.PrivateKey()
        return (key.rawRepresentation.base64EncodedString(), key.publicKey.rawRepresentation.base64EncodedString())
    }

    public static func publicKey(forPrivateKey privateKey: String) throws -> String {
        guard let keyData = Data(base64Encoded: privateKey),
              let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: keyData) else { throw Failure.badPublicKey }
        return key.publicKey.rawRepresentation.base64EncodedString()
    }
}
