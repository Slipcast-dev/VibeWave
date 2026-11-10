import Foundation

/// Поиск поддерживаемых аудиофайлов внутри папки. Берутся только обычные файлы
/// (и символические ссылки на них): каталог с именем «Album.mp3», скрытые файлы
/// и содержимое пакетов (.app, медиатеки и т. п.) в библиотеку не попадают.
public enum MusicFiles {
    private static let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey]

    /// Файлы отсортированы как в Finder («2» раньше «10»).
    /// nil — папка недоступна (отключён диск, нет прав); это не то же самое, что пустая папка.
    /// isCancelled проверяется на каждом элементе; при отмене выбрасывается CancellationError.
    public static func collect(in root: URL, isCancelled: () -> Bool = { false }) throws -> [URL]? {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue,
              manager.isReadableFile(atPath: root.path),
              let enumerator = manager.enumerator(at: root, includingPropertiesForKeys: keys,
                                                 options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return nil }
        var files: [URL] = []
        for case let url as URL in enumerator {
            if isCancelled() { throw CancellationError() }
            // Сначала дешёвая проверка расширения, затем свойства файла (их уже загрузил enumerator).
            if Track.accepts(url), isRegularFile(url) { files.append(url) }
        }
        return files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    /// Обычный файл либо символическая ссылка на обычный файл.
    public static func isRegularFile(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return false }
        if values.isRegularFile == true { return true }
        guard values.isSymbolicLink == true else { return false }
        return (try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }
}
