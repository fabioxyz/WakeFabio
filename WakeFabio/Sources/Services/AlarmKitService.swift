import Foundation
import SwiftUI
import AlarmKit
import AppIntents

public enum AlarmAuthorizationStatus: String, Codable {
    case notDetermined = "Não Solicitado"
    case authorized = "Autorizado"
    case denied = "Negado"
    case unavailable = "Indisponível neste Sistema"
}

public protocol AlarmKitSchedulingProtocol: AnyObject {
    var authorizationStatus: AlarmAuthorizationStatus { get }
    func requestAuthorization() async -> Bool
    func scheduleAlarm(
        id: UUID,
        title: String,
        fireDate: Date,
        soundName: String,
        isRescue: Bool,
        repeatDays: Set<Int>
    ) async throws
    func cancelAlarm(id: UUID) async throws
    func stopAlarmIfAlerting(id: UUID) async throws
    func scheduledAlarmIDs() throws -> Set<UUID>
}

public extension AlarmKitSchedulingProtocol {
    func scheduleAlarm(
        id: UUID,
        title: String,
        fireDate: Date,
        soundName: String,
        isRescue: Bool
    ) async throws {
        try await scheduleAlarm(
            id: id,
            title: title,
            fireDate: fireDate,
            soundName: soundName,
            isRescue: isRescue,
            repeatDays: []
        )
    }
}

/// Implementação nativa real com a framework oficial AlarmKit da Apple (iOS 26+)
public final class NativeAlarmKitService: AlarmKitSchedulingProtocol {
    public static let shared = NativeAlarmKitService()
    
    private init() {}
    
    public var authorizationStatus: AlarmAuthorizationStatus {
        switch AlarmManager.shared.authorizationState {
        case .authorized:
            return .authorized
        case .denied:
            return .denied
        case .notDetermined:
            return .notDetermined
        @unknown default:
            return .denied
        }
    }
    
    public func requestAuthorization() async -> Bool {
        do {
            let state = try await AlarmManager.shared.requestAuthorization()
            return state == .authorized
        } catch {
            print("[AlarmKit] Falha na autorização do AlarmKit: \(error)")
            return false
        }
    }
    
    public func scheduleAlarm(
        id: UUID,
        title: String,
        fireDate: Date,
        soundName: String,
        isRescue: Bool,
        repeatDays: Set<Int> = []
    ) async throws {
        // Qualificação explícita como AlarmKit.Alarm.Schedule para evitar colisão com o modelo local Alarm
        let schedule: AlarmKit.Alarm.Schedule
        
        if isRescue || repeatDays.isEmpty {
            // One-offs e alarmes de resgate usam timestamp exato absoluto sem descartar data/segundos
            schedule = AlarmKit.Alarm.Schedule.fixed(fireDate)
        } else {
            // Alarme recorrente principal com base no horário e repetição semanal
            let calendar = Calendar.current
            let hour = calendar.component(.hour, from: fireDate)
            let minute = calendar.component(.minute, from: fireDate)
            let time = AlarmKit.Alarm.Schedule.Relative.Time(hour: hour, minute: minute)
            
            let weekdays: [Locale.Weekday] = repeatDays.sorted().compactMap { day in
                switch day {
                case 1: return .sunday
                case 2: return .monday
                case 3: return .tuesday
                case 4: return .wednesday
                case 5: return .thursday
                case 6: return .friday
                case 7: return .saturday
                default: return nil
                }
            }
            schedule = AlarmKit.Alarm.Schedule.relative(
                .init(time: time, repeats: .weekly(weekdays))
            )
        }
        
        let localizedTitle = LocalizedStringResource(stringLiteral: title)
        let stopButton = AlarmButton(
            text: LocalizedStringResource(stringLiteral: "Parar"),
            textColor: .white,
            systemImageName: "stop.fill"
        )
        
        let missionIntent = OpenWakeFabioMissionIntent(occurrenceId: id.uuidString)
        let secondaryButton = AlarmButton(
            text: LocalizedStringResource(stringLiteral: "Missão"),
            textColor: .white,
            systemImageName: "checklist"
        )
        let alertContent = AlarmPresentation.Alert(
            title: localizedTitle,
            stopButton: stopButton,
            secondaryButton: secondaryButton,
            secondaryButtonBehavior: .custom
        )
        
        let presentation = AlarmPresentation(alert: alertContent)
        
        struct WakeFabioAlarmMetadata: AlarmMetadata {}
        let attributes = AlarmAttributes(
            presentation: presentation,
            metadata: WakeFabioAlarmMetadata(),
            tintColor: isRescue ? .red : .orange
        )
        
        let configuration = AlarmManager.AlarmConfiguration.alarm(
            schedule: schedule,
            attributes: attributes,
            secondaryIntent: missionIntent,
            sound: AlarmSoundCatalog.url(for: soundName) == nil
                ? .default : .named(AlarmSoundCatalog.resolvedName(soundName))
        )
        
        _ = try await AlarmManager.shared.schedule(id: id, configuration: configuration)
        print("[AlarmKit] Alarme agendado no SO. ID: \(id), Data: \(fireDate), Resgate: \(isRescue)")
    }
    
    public func cancelAlarm(id: UUID) async throws {
        try await AlarmManager.shared.cancel(id: id)
        print("[AlarmKit] Alarme cancelado com sucesso no sistema: ID \(id)")
    }
    
    public func scheduledAlarmIDs() throws -> Set<UUID> {
        Set(try AlarmManager.shared.alarms.map(\.id))
    }

    /// Stop the current alert without cancelling a recurring schedule.
    public func stopAlarmIfAlerting(id: UUID) async throws {
        let alarms = try AlarmManager.shared.alarms
        if alarms.contains(where: { $0.id == id && $0.state == .alerting }) {
            try AlarmManager.shared.stop(id: id)
        }
    }
    
    /// Observa eventos de disparo e atualizações de alarme diretamente do AlarmKit
    public func startObservingAlarmUpdates(
        onUpdate: @escaping @Sendable (UUID) -> Void
    ) -> Task<Void, Never> {
        Task {
            for await alarms in AlarmManager.shared.alarmUpdates {
                guard !Task.isCancelled else { return }
                for alarm in alarms where alarm.state == .alerting {
                    onUpdate(alarm.id)
                }
            }
        }
    }
}
