import AVFoundation
import UIKit

/// 다운로드 중에만 무음 오디오를 루프 재생해 앱 프로세스가 suspend 되지 않게 한다.
/// (LiveContainer 호스트 Info.plist에 UIBackgroundModes=audio 가 있어 동작함)
final class KeepAlive {
    static let shared = KeepAlive()
    static let enabledKey = "keepAliveEnabled"

    private var player: AVAudioPlayer?
    private var active = false
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    var enabled: Bool {
        UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    private init() {
        let center = NotificationCenter.default
        center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            guard let self,
                  let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
            self.player?.stop()
            self.apply()
        }
        center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            self?.player = nil
            self?.apply()
        }
    }

    func setActive(_ value: Bool) {
        active = value
        apply()
    }

    func settingsChanged() {
        apply()
    }

    func appDidEnterBackground() {
        endBackgroundTask()
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "BackDown") { [weak self] in
            self?.endBackgroundTask()
        }
    }

    func appWillEnterForeground() {
        endBackgroundTask()
        apply()
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    private func apply() {
        if active && enabled { start() } else { stop() }
    }

    private func start() {
        if player?.isPlaying == true { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            if player == nil {
                let p = try AVAudioPlayer(data: Self.silentWAV())
                p.numberOfLoops = -1
                p.volume = 0
                p.prepareToPlay()
                player = p
            }
            player?.play()
        } catch {
            print("KeepAlive start failed: \(error)")
        }
    }

    private func stop() {
        guard player != nil else { return }
        player?.stop()
        player = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// 1초짜리 8kHz mono 16-bit 무음 WAV
    private static func silentWAV() -> Data {
        let sampleRate: UInt32 = 8000
        let dataSize: UInt32 = sampleRate * 2
        var d = Data()
        func str(_ s: String) { d.append(contentsOf: Array(s.utf8)) }
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        str("RIFF"); u32(36 + dataSize); str("WAVE")
        str("fmt "); u32(16); u16(1); u16(1); u32(sampleRate); u32(sampleRate * 2); u16(2); u16(16)
        str("data"); u32(dataSize)
        d.append(Data(count: Int(dataSize)))
        return d
    }
}
