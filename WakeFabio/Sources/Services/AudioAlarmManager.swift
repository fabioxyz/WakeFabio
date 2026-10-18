import Foundation
import AVFoundation
import Combine
import AudioToolbox

public final class AudioAlarmManager: NSObject, ObservableObject, AVAudioPlayerDelegate {
    public static let shared = AudioAlarmManager()
    
    // Três canais de áudio independentes para evitar colisão entre alarme e efeitos sonoros
    private var alarmPlayer: AVAudioPlayer?
    private var sfxPlayer: AVAudioPlayer?
    private var previewPlayer: AVAudioPlayer?
    
    @Published public var isAlarmRinging: Bool = false
    @Published public var isPreviewPlaying: Bool = false
    @Published public var currentlyPreviewedSound: String? = nil
    @Published public var lastAudioError: String? = nil
    
    public override init() {
        super.init()
        configureAudioSession()
        setupInterruptionObserver()
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
        alarmPlayer?.stop()
        previewPlayer?.stop()
        sfxPlayer?.stop()
    }
    
    private func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            print("[Audio] Erro ao configurar AVAudioSession: \(error)")
        }
    }
    
    private func setupInterruptionObserver() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioInterruption),
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance()
        )
    }
    
    @objc private func handleAudioInterruption(notification: Notification) {
        guard let info = notification.userInfo,
              let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
        
        switch type {
        case .began:
            print("[Audio] Interrupção de áudio iniciada (chamada telefónica/alarme do sistema).")
            alarmPlayer?.pause()
        case .ended:
            if let optionsValue = info[AVAudioSessionInterruptionOptionKey] as? UInt {
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                if options.contains(.shouldResume) && isAlarmRinging {
                    alarmPlayer?.play()
                }
            }
        @unknown default:
            break
        }
    }
    
    // MARK: - Canal 1: Alarme Contínuo (Loop Infinito)
    
    public func playAlarm(soundName: String = "loud1.mp3") {
        stopPreview()
        
        configureAudioSession()
        guard let url = AlarmSoundCatalog.url(for: soundName) else {
            print("[Audio] Som de alarme não encontrado: \(soundName). Usando alerta sonoro do sistema.")
            AudioServicesPlaySystemSound(1005)
            DispatchQueue.main.async { self.isAlarmRinging = true }
            return
        }
        
        do {
            alarmPlayer = try AVAudioPlayer(contentsOf: url)
            alarmPlayer?.numberOfLoops = -1 // Loop contínuo ininterrupto
            alarmPlayer?.volume = 1.0
            alarmPlayer?.prepareToPlay()
            alarmPlayer?.play()
            
            DispatchQueue.main.async {
                self.isAlarmRinging = true
            }
        } catch {
            print("[Audio] Erro ao instanciar player de alarme: \(error)")
        }
    }
    
    public func stopAlarm() {
        alarmPlayer?.stop()
        alarmPlayer = nil
        DispatchQueue.main.async {
            self.isAlarmRinging = false
        }
    }
    
    // MARK: - Canal 2: Efeitos Sonoros de Missão (SFX One-Shot)
    
    public func playSFX(soundName: String) {
        let (resource, ext) = parseSoundName(soundName)
        guard let url = Bundle.main.url(forResource: resource, withExtension: ext) else {
            // Feedback háptico/sistema como fallback
            AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
            return
        }
        
        do {
            sfxPlayer = try AVAudioPlayer(contentsOf: url)
            sfxPlayer?.numberOfLoops = 0 // Disparo único sem interromper alarme principal
            sfxPlayer?.volume = 0.9
            sfxPlayer?.prepareToPlay()
            sfxPlayer?.play()
        } catch {
            print("[Audio] Erro ao tocar SFX (\(soundName)): \(error)")
        }
    }
    
    public func playSuccessChime() {
        playSFX(soundName: "wordbeat_success.mp3")
    }
    
    public func playFailureChime() {
        playSFX(soundName: "wordbeat_failure.mp3")
    }
    
    // MARK: - Canal 3: Pré-escuta de Toques no Editor (Preview Player)
    
    public func playPreview(soundName: String) {
        if isPreviewPlaying && currentlyPreviewedSound == soundName {
            stopPreview()
            return
        }
        
        stopPreview()
        lastAudioError = nil
        configureAudioSession()
        guard let url = AlarmSoundCatalog.url(for: soundName) else {
            lastAudioError = "Não foi possível encontrar este toque."
            return
        }
        
        do {
            previewPlayer = try AVAudioPlayer(contentsOf: url)
            previewPlayer?.delegate = self
            previewPlayer?.numberOfLoops = 0
            previewPlayer?.volume = 0.8
            previewPlayer?.prepareToPlay()
            guard previewPlayer?.play() == true else {
                stopPreview()
                lastAudioError = "Não foi possível reproduzir o toque. Tenta novamente."
                return
            }
            isPreviewPlaying = true
            currentlyPreviewedSound = soundName
        } catch {
            stopPreview()
            lastAudioError = "Não foi possível reproduzir o toque: \(error.localizedDescription)"
        }
    }
    
    public func stopPreview() {
        previewPlayer?.stop()
        previewPlayer = nil
        isPreviewPlaying = false
        currentlyPreviewedSound = nil
    }
    
    public func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        if player == previewPlayer {
            stopPreview()
        }
    }
    
    public func stopAll() {
        stopAlarm()
        stopPreview()
        sfxPlayer?.stop()
        sfxPlayer = nil
    }
    
    // MARK: - Utilitários
    
    private func parseSoundName(_ soundName: String) -> (String, String) {
        let ns = soundName as NSString
        let resource = ns.deletingPathExtension
        let ext = ns.pathExtension.isEmpty ? "mp3" : ns.pathExtension
        return (resource, ext)
    }
    
    public static let availableSounds = AlarmSoundCatalog.sounds
}
