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

    /// Проверяет подпись описания, архив (контрольная сумма и подпись Ed25519), распаковывает его и проверяет
    /// приложение внутри: идентификатор, версию и подпись кода. Возвращает путь к новому VibeWave.app.
    static func prepare(archive: URL, manifest: UpdateManifest, publicKeys: [String], bundleIdentifier: String,
                        workDirectory: URL) throws -> URL {
        try UpdateSignature.verifyManifest(manifest, publicKeys: publicKeys)
        let data = try Data(contentsOf: archive)
        try UpdateSignature.verify(data, manifest: manifest, publicKeys: publicKeys)
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

    /// SHA-256 исполняемого файла проверенного приложения. Исполняемый файл содержит подпись кода,
    /// которая закрепляет Info.plist и все ресурсы, поэтому любая подмена бандла после проверки
    /// меняет этот хэш. Установщик сверяет его непосредственно перед заменой.
    static func executableDigest(_ app: URL) throws -> String {
        let executable = app.appendingPathComponent("Contents/MacOS/VibeWave")
        guard MusicFiles.isRegularFile(executable) else { throw Failure.bundle }
        return UpdateSignature.sha256Hex(try Data(contentsOf: executable, options: .mappedIfSafe))
    }

    /// Запускает отдельный процесс, который дождётся завершения VibeWave (pid), заменит приложение
    /// по адресу target новым и при relaunch откроет его снова. Если у пользователя нет прав на запись
    /// (например, приложение установлено от имени администратора), macOS попросит пароль.
    /// Текст сценария передаётся аргументом `sh -c`, а не файлом во временной папке: его нельзя
    /// подменить до запуска с правами администратора. `digest` — результат `executableDigest`.
    @discardableResult
    static func launchInstaller(newApp: URL, target: URL, waitingFor pid: Int32, relaunch: Bool,
                                digest: String) throws -> Process {
        guard digest.count == 64, digest.allSatisfy(\.isHexDigit) else { throw Failure.codeSignature }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", installScript, "vibewave-install", "install", String(pid), target.path, newApp.path,
                             relaunch ? "1" : "0", digest.lowercased()]
        // Тот же текст нужен шагу с правами администратора: он получает его аргументом osascript.
        var environment = ProcessInfo.processInfo.environment
        environment["VIBEWAVE_INSTALL_SCRIPT"] = installScript
        process.environment = environment
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
    /// на место, если новую поставить не удалось. Новое приложение сначала переносится рядом
    /// с целевым (`.vibewave-incoming`), затем проверяются подпись кода и хэш исполняемого файла,
    /// и только после этого оно занимает место прежнего. Символьные ссылки вместо бандла отклоняются.
    static let installScript = #"""
    # install <pid> <target.app> <new.app> <relaunch 0|1> <sha256>  — дождаться выхода VibeWave и заменить
    # swap <target.app> <new.app> <sha256>                           — только замена (с правами администратора)
    verify() {
        [ -d "$1" ] && [ ! -L "$1" ] || return 1
        /usr/bin/codesign --verify --strict "$1" >/dev/null 2>&1 || return 1
        [ -f "$1/Contents/MacOS/VibeWave" ] && [ ! -L "$1/Contents/MacOS/VibeWave" ] || return 1
        actual=$(/usr/bin/shasum -a 256 "$1/Contents/MacOS/VibeWave" | /usr/bin/cut -d ' ' -f 1)
        [ -n "$2" ] && [ "$actual" = "$2" ]
    }
    swap() {
        target="$1"; new="$2"; digest="$3"
        incoming="$target.vibewave-incoming"; backup="$target.vibewave-previous"
        [ -d "$new" ] && [ ! -L "$new" ] || return 1
        rm -rf "$incoming" "$backup"
        mv "$new" "$incoming" || return 1
        if ! verify "$incoming" "$digest"; then rm -rf "$incoming"; return 1; fi
        if [ -e "$target" ] || [ -L "$target" ]; then
            if ! mv "$target" "$backup"; then rm -rf "$incoming"; return 1; fi
        fi
        if mv "$incoming" "$target"; then
            rm -rf "$backup"
            xattr -dr com.apple.quarantine "$target" 2>/dev/null
            # Установленное администратором приложение не должно стать доступным для записи пользователю.
            if [ "$(id -u)" = 0 ]; then chown -R root:admin "$target" && chmod -R go-w "$target"; fi
            return 0
        fi
        rm -rf "$incoming"
        [ -e "$backup" ] && mv "$backup" "$target"
        return 1
    }
    case "$1" in
    swap)
        swap "$2" "$3" "$4"
        ;;
    install)
        pid="$2"; target="$3"; new="$4"; relaunch="$5"; digest="$6"
        tries=0
        while kill -0 "$pid" 2>/dev/null; do
            sleep 0.2
            tries=$((tries + 1))
            [ "$tries" -gt 600 ] && exit 1
        done
        parent=$(dirname "$target")
        if [ -w "$parent" ] && { [ ! -e "$target" ] || [ -w "$target" ]; }; then
            swap "$target" "$new" "$digest" || exit 1
        else
            /usr/bin/osascript - "$VIBEWAVE_INSTALL_SCRIPT" "$target" "$new" "$digest" <<'APPLESCRIPT' || exit 1
    on run argv
        do shell script "/bin/sh -c " & quoted form of item 1 of argv & " vibewave-install swap " & quoted form of item 2 of argv & " " & quoted form of item 3 of argv & " " & quoted form of item 4 of argv with administrator privileges
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
