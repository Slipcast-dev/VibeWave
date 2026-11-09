import Foundation
import VibeWaveCore

/// Ключ подписи обновлений VibeWave (Ed25519).
///   update-signer generate      — создать закрытый ключ, если его нет, и вывести открытый
///   update-signer public        — вывести открытый ключ
///   update-signer sign <файл>   — вывести подпись файла в Base64
///   update-signer manifest <zip> <версия> <url> [заметки ru] [заметки en] — вывести update.json
/// Закрытый ключ хранится вне репозитория: $VIBEWAVE_UPDATE_KEY или ~/.config/vibewave/update-signing-key.
/// Без него нельзя выпустить обновление, которое примут уже установленные копии: сохраните резервную копию.
@main
struct UpdateSigner {
    static var keyURL: URL {
        if let path = ProcessInfo.processInfo.environment["VIBEWAVE_UPDATE_KEY"], !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/vibewave/update-signing-key")
    }

    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(1)
    }

    static func readKey() -> String {
        guard let key = try? String(contentsOf: keyURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty else { fail("Нет ключа подписи: \(keyURL.path). Создайте его командой generate.") }
        return key
    }

    static func main() throws {
        let arguments = CommandLine.arguments.dropFirst()
        switch arguments.first {
        case "generate":
            if !FileManager.default.fileExists(atPath: keyURL.path) {
                let pair = UpdateSignature.generateKeyPair()
                try FileManager.default.createDirectory(at: keyURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
                guard FileManager.default.createFile(atPath: keyURL.path, contents: Data(pair.privateKey.utf8),
                                                     attributes: [.posixPermissions: 0o600]) else { fail("Не удалось записать \(keyURL.path)") }
                FileHandle.standardError.write(Data("Создан ключ подписи: \(keyURL.path)\n".utf8))
            }
            print(try UpdateSignature.publicKey(forPrivateKey: readKey()))
        case "public":
            print(try UpdateSignature.publicKey(forPrivateKey: readKey()))
        case "sign":
            guard arguments.count == 2, let path = arguments.last else { fail("Использование: update-signer sign <файл>") }
            print(try UpdateSignature.sign(try Data(contentsOf: URL(fileURLWithPath: path)), privateKey: readKey()))
        case "manifest":
            let values = Array(arguments.dropFirst())
            guard values.count >= 3, let url = URL(string: values[2]) else {
                fail("Использование: update-signer manifest <zip> <версия> <url> [заметки ru] [заметки en]")
            }
            let archive = try Data(contentsOf: URL(fileURLWithPath: values[0]))
            var notes: [String: String] = [:]
            if values.count > 3, !values[3].isEmpty { notes["ru"] = values[3] }
            if values.count > 4, !values[4].isEmpty { notes["en"] = values[4] }
            let manifest = UpdateManifest(version: values[1], url: url, sha256: UpdateSignature.sha256Hex(archive),
                                          signature: try UpdateSignature.sign(archive, privateKey: readKey()), notes: notes)
            // Самопроверка: подпись должна проходить той же проверкой, что и в приложении.
            try UpdateSignature.verify(archive, manifest: manifest, publicKey: UpdateSignature.publicKey(forPrivateKey: readKey()))
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            print(String(decoding: try encoder.encode(manifest), as: UTF8.self))
        default:
            fail("Использование: update-signer generate | public | sign <файл> | manifest <zip> <версия> <url>")
        }
    }
}
