import Combine
import Foundation

/// Текущая позиция воспроизведения. Обновляется таймером четыре раза в секунду,
/// поэтому за ней следят только табло времени, полоса позиции и Now Playing,
/// а не все представления `PlayerModel`.
@MainActor
final class PlaybackClock: ObservableObject {
    @Published var position: Double = 0
}
