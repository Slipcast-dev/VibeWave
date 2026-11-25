import Foundation
import Security
import VibeWaveCore

/// Ключ подписи обновлений VibeWave (Ed25519).
///   update-signer generate      — создать закрытый ключ в Связке ключей, если его нет, и вывести открытый
///   update-signer public        — вывести открытый ключ
///   update-signer has-key       — код выхода 0, если ключ доступен
///   update-signer keychain-import — перенести ключ из файла в Связку ключей (файл не удаляется)
///   update-signer sign <файл>   — вывести подпись файла в Base64
///   update-signer manifest <zip> <версия> <url> [заметки ru] [заметки en] — вывести подписанный update.json
///
/// Где ищется закрытый ключ:
/// 1. `$VIBEWAVE_UPDATE_KEY` — путь к файлу (явный выбор, например для резервной копии);
/// 2. Связка ключей входа: элемент «VibeWave update signing key» (предпочтительно — ключ зашифрован
///    и не лежит открытым файлом);
/// 3. прежний файл `~/.config/vibewave/update-signing-key`.
/// Без ключа нельзя выпустить обновление, которое примут уже установленные копии: сохраните резервную копию.
@main
struct UpdateSigner {
    static let keychainService = "VibeWave update signing key"
    static let keychainAccount = "VibeWave"

    static var explicitKeyURL: URL? {
        guard let path = ProcessInfo.processInfo.environment["VIBEWAVE_UPDATE_KEY"], !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }

    static var legacyKeyURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/vibewave/update-signing-key")
    }

    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(1)
    }

    static func readFile(_ url: URL) -> String? {
        guard let key = try? String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty else { return nil }
        return key
    }

    static func readKeychain() -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword, kSecAttrService: keychainService,
            kSecAttrAccount: keychainAccount, kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data,
              let key = String(data: data, encoding: .utf8), !key.isEmpty else { return nil }
        return key
    }

    static func storeKeychain(_ key: String) {
        let item: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword, kSecAttrService: keychainService, kSecAttrAccount: keychainAccount,
            kSecAttrLabel: keychainService, kSecValueData: Data(key.utf8),
            kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { fail("Не удалось записать ключ в Связку ключей (OSStatus \(status))") }
    }

    static func findKey() -> (key: String, source: String)? {
        if let url = explicitKeyURL { return readFile(url).map { ($0, url.path) } }
        if let key = readKeychain() { return (key, "Связка ключей: \(keychainService)") }
        return readFile(legacyKeyURL).map { ($0, legacyKeyURL.path) }
    }

    static func readKey() -> String {
        guard let found = findKey() else {
            fail("Нет ключа подписи: ни $VIBEWAVE_UPDATE_KEY, ни Связки ключей, ни \(legacyKeyURL.path). Создайте его командой generate.")
        }
        return found.key
    }

    static func main() throws {
        let arguments = CommandLine.arguments.dropFirst()
        switch arguments.first {
        case "generate":
            if findKey() == nil {
                let pair = UpdateSignature.generateKeyPair()
                if let url = explicitKeyURL {
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                            attributes: [.posixPermissions: 0o700])
                    guard FileManager.default.createFile(atPath: url.path, contents: Data(pair.privateKey.utf8),
                                                         attributes: [.posixPermissions: 0o600]) else { fail("Не удалось записать \(url.path)") }
                } else {
                    storeKeychain(pair.privateKey)
                }
                FileHandle.standardError.write(Data("Создан ключ подписи: \(findKey()?.source ?? "?")\n".utf8))
            }
            print(try UpdateSignature.publicKey(forPrivateKey: readKey()))
        case "public":
            print(try UpdateSignature.publicKey(forPrivateKey: readKey()))
        case "has-key":
            guard let found = findKey() else { exit(1) }
            FileHandle.standardError.write(Data("Ключ подписи: \(found.source)\n".utf8))
        case "keychain-import":
            let source = explicitKeyURL ?? legacyKeyURL
            guard let key = readFile(source) else { fail("Нет файла ключа: \(source.path)") }
            if let existing = readKeychain() {
                guard existing == key else { fail("В Связке ключей уже другой ключ «\(keychainService)»") }
            } else {
                storeKeychain(key)
            }
            FileHandle.standardError.write(Data("""
                Ключ из \(source.path) сохранён в Связке ключей. Проверьте выпуск, затем сохраните файл \
                в надёжной резервной копии и удалите его с диска.\n
                """.utf8))
        case "sign":
            guard arguments.count == 2, let path = arguments.last else { fail("Использование: update-signer sign <файл>") }
            print(try UpdateSignature.sign(try Data(contentsOf: URL(fileURLWithPath: path)), privateKey: readKey()))
        case "manifest":
            let values = Array(arguments.dropFirst())
            guard values.count >= 3, let url = URL(string: values[2]) else {
                fail("Использование: update-signer manifest <zip> <версия> <url> [заметки ru] [заметки en]")
            }
            let key = readKey()
            let archive = try Data(contentsOf: URL(fileURLWithPath: values[0]))
            var notes: [String: String] = [:]
            if values.count > 3, !values[3].isEmpty { notes["ru"] = values[3] }
            if values.count > 4, !values[4].isEmpty { notes["en"] = values[4] }
            let unsigned = UpdateManifest(version: values[1], url: url, sha256: UpdateSignature.sha256Hex(archive),
                                          signature: try UpdateSignature.sign(archive, privateKey: key), notes: notes)
            let manifest = try UpdateSignature.signManifest(unsigned, privateKey: key)
            // Самопроверка: подписи должны проходить той же проверкой, что и в приложении,
            // в том числе после записи в JSON и повторного чтения.
            let publicKey = try UpdateSignature.publicKey(forPrivateKey: key)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let json = try encoder.encode(manifest)
            let decoded = try JSONDecoder().decode(UpdateManifest.self, from: json)
            try UpdateSignature.verify(archive, manifest: decoded, publicKeys: [publicKey])
            try UpdateSignature.verifyManifest(decoded, publicKeys: [publicKey])
            print(String(decoding: json, as: UTF8.self))
        default:
            fail("Использование: update-signer generate | public | has-key | keychain-import | sign <файл> | manifest <zip> <версия> <url>")
        }
    }
}
