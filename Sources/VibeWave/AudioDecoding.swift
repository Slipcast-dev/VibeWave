import AVFoundation
import AudioToolbox
import VibeWaveCore

/// Импорт и плеер используют одинаковые проверки контейнера и декодера.
/// Пробное чтение ограничено началом потока и не заменяет полную проверку файла.
enum AudioDecoding {
    enum Failure: Error {
        case unsupportedFile, unreadableFile, protected, invalidAudio, emptyAudio
    }

    static func validateExtension(_ url: URL) throws {
        if url.isFileURL && url.pathExtension.lowercased() == "m4p" { throw Failure.protected }
        guard AudioFormat(url: url) != nil else { throw Failure.unsupportedFile }
    }

    static func open(_ url: URL) throws -> AudioPCMSource {
        try validateExtension(url)
        guard MusicFiles.isRegularFile(url), FileManager.default.isReadableFile(atPath: url.path) else {
            throw Failure.unreadableFile
        }
        let file = try AudioPCMSources.open(url)
        let format = file.processingFormat
        guard file.length > 0 else { throw Failure.emptyAudio }
        guard format.sampleRate.isFinite, format.sampleRate > 0, format.channelCount > 0,
              let sample = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 256) else {
            throw Failure.invalidAudio
        }
        try file.read(into: sample)
        guard sample.frameLength > 0 else { throw Failure.emptyAudio }
        file.framePosition = 0
        return file
    }

    static func message(_ error: Error, strings: Strings) -> String {
        if let failure = error as? OggFailure {
            return failure == .unsupportedStream ? strings.audioUnsupportedCodec : strings.audioInvalid
        }
        switch error as? Failure {
        case .unsupportedFile: return strings.errorNoSupportedFiles
        case .unreadableFile: return strings.audioUnreadable
        case .protected: return strings.audioProtected
        case .invalidAudio: return strings.audioInvalid
        case .emptyAudio: return strings.audioEmpty
        case nil:
            let error = error as NSError
            if error.domain == AVFoundationErrorDomain {
                if [AVError.Code.contentIsProtected, .contentIsNotAuthorized].contains(where: { $0.rawValue == error.code }) {
                    return strings.audioProtected
                }
                if AVError.Code.decoderNotFound.rawValue == error.code { return strings.audioUnsupportedCodec }
                if [AVError.Code.fileFormatNotRecognized, .fileFailedToParse, .decodeFailed, .invalidSourceMedia]
                    .contains(where: { $0.rawValue == error.code }) { return strings.audioInvalid }
            }
            // ExtAudioFileOpenURL возвращает те же OSStatus через домен AVFAudio.
            if error.domain == NSOSStatusErrorDomain || error.domain == "com.apple.coreaudio.avfaudio" {
                if error.code == Int(kAudioFilePermissionsError) { return strings.audioUnreadable }
                if [kAudioFileUnsupportedDataFormatError, kAudioConverterErr_FormatNotSupported].contains(where: { Int($0) == error.code }) {
                    return strings.audioUnsupportedCodec
                }
                if [kAudioFileUnsupportedFileTypeError, kAudioFileInvalidFileError].contains(where: { Int($0) == error.code }) {
                    return strings.audioInvalid
                }
            }
            return error.localizedDescription
        }
    }
}
