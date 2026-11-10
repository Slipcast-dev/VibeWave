import AudioToolbox
import Foundation

/// Только чтение тегов и встроенной обложки MPEG-4. Объекты Core Foundation,
/// возвращённые свойствами AudioFile, принадлежат вызывающей стороне.
enum MPEG4Metadata {
    static func read(_ url: URL, includeArtwork: Bool) throws -> AudioMetadata {
        var handle: AudioFileID?
        let status = AudioFileOpenURL(url as CFURL, .readPermission, 0, &handle)
        guard status == noErr, let file = handle else { throw AudioMetadataFile.Failure.unsupportedLayout }
        defer { AudioFileClose(file) }

        var metadata = AudioMetadata()
        if let info: CFDictionary = readProperty(kAudioFilePropertyInfoDictionary, from: file) {
            let values = info as NSDictionary
            let keys: [AudioTagField: String] = [
                .title: kAFInfoDictionary_Title, .artist: kAFInfoDictionary_Artist,
                .album: kAFInfoDictionary_Album, .genre: kAFInfoDictionary_Genre,
                .year: kAFInfoDictionary_Year, .track: kAFInfoDictionary_TrackNumber,
                .comment: kAFInfoDictionary_Comments
            ]
            for (field, key) in keys {
                if let text = values[key] as? String, !text.isEmpty { metadata.fields[field] = text }
                else if let number = values[key] as? NSNumber { metadata.fields[field] = number.stringValue }
            }
        }
        if includeArtwork, let artwork: CFData = readProperty(kAudioFilePropertyAlbumArtwork, from: file),
           (1...AudioArtwork.maximumSize).contains(CFDataGetLength(artwork)) {
            let bytes = artwork as Data
            let mime: String
            if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { mime = "image/jpeg" }
            else if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { mime = "image/png" }
            else { return metadata }
            metadata.artwork = AudioArtwork(data: bytes, mime: mime)
        }
        return metadata
    }

    private static func readProperty<Value: AnyObject>(_ property: AudioFilePropertyID, from file: AudioFileID) -> Value? {
        var retained: Unmanaged<Value>?
        var size = UInt32(MemoryLayout.size(ofValue: retained))
        let status = withUnsafeMutablePointer(to: &retained) { pointer in
            AudioFileGetProperty(file, property, &size, UnsafeMutableRawPointer(pointer))
        }
        return status == noErr ? retained?.takeRetainedValue() : nil
    }
}
