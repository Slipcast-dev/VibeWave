import Foundation
import VibeWaveCore

/// Подготовка и установка обновления без участия интерфейса. Работает в фоне,
/// не трогает модель и вызывается из `Updater` и регрессионных проверок.
enum UpdateInstaller {
    enum Failure: LocalizedError {
        case download, archive, bundle, version, codeSignature, launch

        var errorDescription: String? {
            switch self {
            case .download: return "download failed"
            case .archive: return "archive could not be unpacked"
            case .bundle: return "archive does not contain VibeWave.app"
            case .version: return "app version does not match the update"
            case .codeSignature: return "code signature is invalid"
            case .launch: return "installer could not be started"
            }
        }
    }

    /// Проверяет архив (контрольная сумма и подпись Ed25519), распаковывает его и проверяет
    /// приложение внутри: идентификатор, версию и подпись кода. Возвращает путь к новому VibeWave.app.
    static func prepare(archive: URL, manifest: UpdateManifest, publicKey: String, bundleIdentifier: String,
                        workDirectory: URL) throws -> URL {
        let data = try Data(contentsOf: archive)
        try UpdateSignature.verify(data, manifest: manifest, publicKey: publicKey)
        let unpacked = workDirectory.appendingPathComponent("unpacked", isDirectory: true)
        try? FileManager.default.removeItem(at: unpacked)
        try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: true)
        guard run("/usr/bin/ditto", ["-x", "-k", archive.path, unpacked.path]) else { throw Failure.archive }
        let app = unpacked.appendingPathComponent("VibeWave.app", isDirectory: true)
        guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              info["CFBundleIdentifier"] as? String == bundleIdentifier else { throw Failure.bundle }
        guard let version = (info["CFBundleShortVersionString"] as? String).flatMap(AppVersion.init),
              let expected = AppVersion(manifest.version), version == expected else { throw Failure.version }
        guard run("/usr/bin/codesign", ["--verify", "--strict", app.path]) else { throw Failure.codeSignature }
        return app
    }

    /// Запускает отдельный процесс, который дождётся завершения VibeWave (pid), заменит приложение
    /// по адресу target новым и при relaunch откроет его снова. Если у пользователя нет прав на запись
    /// (например, приложение установлено от имени администратора), macOS попросит пароль.
    @discardableResult
    static func launchInstaller(newApp: URL, target: URL, waitingFor pid: Int32, relaunch: Bool,
                                workDirectory: URL) throws -> Process {
        let script = workDirectory.appendingPathComponent("install-update.sh")
        try installScript.write(to: script, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script.path, "install", String(pid), target.path, newApp.path, relaunch ? "1" : "0"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { throw Failure.launch }
        return process
    }

    private static func run(_ tool: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    /// Замена выполняется переименованием: прежняя версия сохраняется рядом и возвращается
    /// на место, если новую поставить не удалось.
    static let installScript = #"""
    #!/bin/sh
    # install <pid> <target.app> <new.app> <relaunch 0|1>  — дождаться выхода VibeWave и заменить приложение
    # swap <target.app> <new.app>                           — только замена (с правами администратора)
    swap() {
        target="$1"; new="$2"; backup="$target.vibewave-previous"
        [ -d "$new" ] || return 1
        rm -rf "$backup"
        if [ -e "$target" ]; then mv "$target" "$backup" || return 1; fi
        if mv "$new" "$target"; then
            rm -rf "$backup"
            xattr -dr com.apple.quarantine "$target" 2>/dev/null
            return 0
        fi
        [ -e "$backup" ] && mv "$backup" "$target"
        return 1
    }
    case "$1" in
    swap)
        swap "$2" "$3"
        ;;
    install)
        pid="$2"; target="$3"; new="$4"; relaunch="$5"
        tries=0
        while kill -0 "$pid" 2>/dev/null; do
            sleep 0.2
            tries=$((tries + 1))
            [ "$tries" -gt 600 ] && exit 1
        done
        parent=$(dirname "$target")
        if [ -w "$parent" ] && { [ ! -e "$target" ] || [ -w "$target" ]; }; then
            swap "$target" "$new" || exit 1
        else
            /usr/bin/osascript - "$0" "$target" "$new" <<'APPLESCRIPT' || exit 1
    on run argv
        do shell script "/bin/sh " & quoted form of item 1 of argv & " swap " & quoted form of item 2 of argv & " " & quoted form of item 3 of argv with administrator privileges
    end run
    APPLESCRIPT
        fi
        [ "$relaunch" = "1" ] && /usr/bin/open "$target"
        exit 0
        ;;
    esac
    exit 1
    """#
}
