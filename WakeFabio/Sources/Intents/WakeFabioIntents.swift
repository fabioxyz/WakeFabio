import Foundation
#if canImport(AppIntents)
import AppIntents

/// Intent em conformidade com LiveActivityIntent para ser acionado por botões do AlarmKit
/// e abrir o aplicativo diretamente na missão de despertar
@available(iOS 16.0, *)
public struct OpenWakeFabioMissionIntent: LiveActivityIntent {
    public static var title: LocalizedStringResource = "Abrir Missão WakeFabio"
    public static var description = IntentDescription("Abre o aplicativo WakeFabio diretamente na missão ativa de despertar.")
    public static var openAppWhenRun: Bool = true
    
    @Parameter(title: "ID da Ocorrência")
    public var occurrenceId: String?
    
    public init() {}
    
    public init(occurrenceId: String) {
        self.occurrenceId = occurrenceId
    }
    
    @MainActor
    public func perform() async throws -> some IntentResult {
        let store = AlarmStore.shared
        let now = Date()
        
        if let idString = occurrenceId, let uuid = UUID(uuidString: idString) {
            // Filtrar apenas ocorrências ativas (não completadas nem canceladas)
            // e ordenar pelas mais recentes para evitar casar com histórico de ID principal reutilizado
            let matchingOccurrences = store.occurrences
                .filter { occ in
                    (occ.id == uuid || occ.primaryAlarmKitId == uuid || occ.rescueAlarmKitId == uuid || occ.wakeUpCheckRescueId == uuid) &&
                    occ.status != .completed &&
                    occ.status != .cancelled &&
                    occ.status != .failed && occ.status != .preparing && occ.status != .cleanupPending &&
                    occ.scheduledFireDate <= now
                }
                .sorted { $0.scheduledFireDate > $1.scheduledFireDate }
            
            if let occ = matchingOccurrences.first {
                // Não reabrir se já estiver em processamento ou check
                if occ.status != .missionPending && occ.status != .wakeUpCheckPending {
                    try store.updateOccurrenceStatus(id: occ.id, status: .missionPending)
                }
            } else if let directOcc = store.occurrence(for: uuid),
                      directOcc.scheduledFireDate <= now,
                      directOcc.status == .scheduled || directOcc.status == .ringing {
                try store.updateOccurrenceStatus(id: uuid, status: .missionPending)
            }
        } else {
            let activeOccurrences = store.occurrences
                .filter { ($0.status == .scheduled || $0.status == .ringing) && $0.scheduledFireDate <= now }
                .sorted { $0.scheduledFireDate > $1.scheduledFireDate }
            
            if let activeOcc = activeOccurrences.first {
                try store.updateOccurrenceStatus(id: activeOcc.id, status: .missionPending)
            }
        }
        
        // Garante reconciliação em foreground
        AlarmSchedulerCoordinator.shared.reconcileInForeground()
        return .result()
    }
}
#endif
