import AppKit
import LocalVoiceCore

@MainActor
final class ActivationSoundPlayer {
    func play(_ option: DictationActivationSoundOption) {
        let sound = NSSound(named: NSSound.Name(option.systemSoundName))
        guard let sound else {
            NSSound.beep()
            return
        }
        sound.stop()
        sound.currentTime = 0
        sound.play()
    }
}
