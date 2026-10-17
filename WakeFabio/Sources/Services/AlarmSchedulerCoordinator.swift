import Foundation
import Combine

public enum SchedulerError: LocalizedError {
    case barcodeRequired
    case permissionDenied
    case schedulingFailed(String)
    case cancellationFailed(String)
    case occurrenceNotFound
    case schedulingInProgress
    case wakeUpCheckTooEarly
    case wakeUpCheckExpired
    
    public var errorDescription: String? {
        switch self {
        case .barcodeRequired:
            return "É obrigatório registar e guardar um Código QR / Barras de referência antes de ativar o alarme."
        case .permissionDenied:
            return "A permissão de AlarmKit foi negada. Abra as Definições do iOS para autorizar os alarmes do WakeFabio."
        case .schedulingFailed(let reason):
            return "Falha ao agendar alarme no sistema operacional: \(reason)"
        case .cancellationFailed(let reason):
            return "Falha ao cancelar agendamento no sistema operacional: \(reason)"
        case .occurrenceNotFound:
            return "Ocorrência do alarme não encontrada."
        case .schedulingInProgress:
            return "Operação de agendamento já em curso para este alarme."
        case .wakeUpCheckTooEarly:
            return "Ainda não atingiu o momento de checagem do Wake Up Check."
        case .wakeUpCheckExpired:
            return "O prazo para confirmação do Wake Up Check expirou."
        }
    }
}

@MainActor
public final class AlarmSchedulerCoordinator: ObservableObject {
    public static let shared = AlarmSchedulerCoordinator()
    
    @Published public var isScheduling: Bool = false
    @Published public var activeErrorMessage: String? = nil
    
    private let alarmKit: AlarmKitSchedulingProtocol
    private let store: AlarmStore
    private let notifications: NotificationAlarmManager
    private var inFlightAlarmIds: Set<UUID> = []
    private var isRecoveringChanges = false
    
    public init(
        alarmKit: AlarmKitSchedulingProtocol = NativeAlarmKitService.shared,
        store: AlarmStore = .shared,
        notifications: NotificationAlarmManager = .shared
    ) {
        self.alarmKit = alarmKit
        self.store = store
        self.notifications = notifications
    }
    
    private func cancelAlarmsIfScheduled(ids: Set<UUID>) async throws {
        let currentlyScheduled = try alarmKit.scheduledAlarmIDs()
        for id in ids where currentlyScheduled.contains(id) {
            try await alarmKit.cancelAlarm(id: id)
        }
    }
    
    // MARK: - Ativação com Prevenção de Concorrência e Rollback Atómico
    
    /// The editor keeps its draft until this operation has committed.
    public func saveAlarm(_ draft: Alarm) async throws {
        guard !inFlightAlarmIds.contains(draft.id) else { throw SchedulerError.schedulingInProgress }
        if draft.isEnabled {
            try await enableAlarm(draft)
        } else if let original = store.alarm(for: draft.id) {
            if original.isEnabled || store.occurrences.contains(where: { $0.alarmId == draft.id }) {
                try await disableAlarm(original)
            }
            try store.updateAlarm(draft)
        } else {
            try store.addAlarm(draft)
        }
    }

    /// Prepare the new pair before touching the old schedules or configuration.
    public func enableAlarm(_ alarm: Alarm) async throws {
        guard !inFlightAlarmIds.contains(alarm.id) else {
            throw SchedulerError.schedulingInProgress
        }
        inFlightAlarmIds.insert(alarm.id)
        isScheduling = true
        defer {
            inFlightAlarmIds.remove(alarm.id)
            isScheduling = !inFlightAlarmIds.isEmpty
        }
        if alarm.missionType == .barcode {
            guard let code = alarm.registeredBarcode,
                  !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw SchedulerError.barcodeRequired
            }
        }
        if alarmKit.authorizationStatus == .notDetermined {
            guard await alarmKit.requestAuthorization() else { throw SchedulerError.permissionDenied }
        }
        guard alarmKit.authorizationStatus == .authorized else { throw SchedulerError.permissionDenied }

        let original = store.alarm(for: alarm.id)
        let previous = store.occurrences.filter { $0.alarmId == alarm.id }
        guard !previous.contains(where: {
            $0.status == .ringing || $0.status == .missionPending || $0.status == .wakeUpCheckPending
        }) else {
            throw SchedulerError.schedulingFailed("Conclua a missão ou desative o alarme antes de editar.")
        }
        let previousIDs = previous.reduce(into: Set<UUID>()) { $0.formUnion($1.systemAlarmIDs) }
        let originallyScheduled = try alarmKit.scheduledAlarmIDs().intersection(previousIDs)
        var staged = OccurrenceState(
            alarmId: alarm.id, scheduledFireDate: alarm.nextFireDate(),
            missionType: alarm.missionType, registeredBarcode: alarm.registeredBarcode,
            mathDifficulty: alarm.mathDifficulty, mathProblemsCount: alarm.mathProblemsCount,
            soundName: alarm.soundName, status: .preparing
        )
        staged.replacementAlarmIDs = Array(originallyScheduled)
        staged.replacementWasEnabled = original?.isEnabled ?? false
        try store.saveOccurrence(staged)
        do {
            try await alarmKit.scheduleAlarm(
                id: staged.primaryAlarmKitId, title: "⏰ \(alarm.label)",
                fireDate: staged.scheduledFireDate, soundName: alarm.soundName,
                isRescue: false, repeatDays: alarm.repeatDays
            )
            try await alarmKit.scheduleAlarm(
                id: staged.rescueAlarmKitId, title: "🚨 RESGATE: \(alarm.label)",
                fireDate: staged.scheduledFireDate.addingTimeInterval(180),
                soundName: alarm.soundName, isRescue: true
            )
            try await cancelAlarmsIfScheduled(ids: previousIDs)
            var enabled = alarm
            enabled.isEnabled = true
            var confirmed = staged
            confirmed.status = .scheduled
            confirmed.replacementAlarmIDs = nil
            confirmed.replacementWasEnabled = nil
            try store.commitAlarm(enabled, occurrence: confirmed)
            for occurrence in previous { notifications.cancelNotifications(for: occurrence.id) }
        } catch {
            let failure = error.localizedDescription
            var recoveryErrors: [String] = []
            // Restore any old schedules already cancelled by a partial replacement.
            do {
                try await restorePreviousSchedules(original, occurrences: previous, ids: originallyScheduled)
            } catch { recoveryErrors.append(error.localizedDescription) }
            do {
                try await cancelAlarmsIfScheduled(ids: staged.systemAlarmIDs)
                try store.removeOccurrence(id: staged.id)
            } catch {
                recoveryErrors.append(error.localizedDescription)
                staged.status = .cleanupPending
                do { try store.saveOccurrence(staged) }
                catch { recoveryErrors.append(error.localizedDescription) }
            }
            if !recoveryErrors.isEmpty {
                if var disabled = original {
                    disabled.isEnabled = false
                    do { try store.updateAlarm(disabled) }
                    catch { recoveryErrors.append(error.localizedDescription) }
                }
                activeErrorMessage = "Edição não concluída; existem operações a recuperar. " + recoveryErrors.joined(separator: "; ")
            }
            throw SchedulerError.schedulingFailed(failure + (recoveryErrors.isEmpty
                ? " A configuração anterior foi preservada."
                : " Há identificadores guardados para recuperação; tente novamente ou desative o alarme."))
        }
    }

    private func restorePreviousSchedules(_ alarm: Alarm?, occurrences: [OccurrenceState], ids: Set<UUID>) async throws {
        guard let alarm = alarm, alarm.isEnabled else { return }
        var live = try alarmKit.scheduledAlarmIDs()
        for occurrence in occurrences where occurrence.status != .preparing && occurrence.status != .cleanupPending {
            let primaryDate = alarm.repeatDays.isEmpty ? occurrence.scheduledFireDate : alarm.nextFireDate()
            var requests: [(UUID, Date, Bool, Set<Int>)] = [
                (occurrence.primaryAlarmKitId, primaryDate, false, alarm.repeatDays),
                (occurrence.rescueAlarmKitId, occurrence.scheduledFireDate.addingTimeInterval(180), true, [])
            ]
            if let id = occurrence.wakeUpCheckRescueId, let deadline = occurrence.wakeUpCheckDeadline {
                requests.append((id, deadline, true, []))
            }
            for (id, date, isRescue, days) in requests where ids.contains(id) && !live.contains(id) {
                // An elapsed one-off must not be moved into tomorrow as a side effect of recovery.
                guard date > Date() else { continue }
                try await alarmKit.scheduleAlarm(id: id, title: alarm.label, fireDate: date,
                    soundName: alarm.soundName, isRescue: isRescue, repeatDays: days)
                live.insert(id)
            }
        }
    }

    /// Desativa o alarme e propaga erros se o cancelamento no SO falhar
    public func disableAlarm(_ alarm: Alarm) async throws {
        guard !inFlightAlarmIds.contains(alarm.id) else {
            throw SchedulerError.schedulingInProgress
        }
        inFlightAlarmIds.insert(alarm.id)
        isScheduling = true
        defer {
            inFlightAlarmIds.remove(alarm.id)
            isScheduling = false
        }
        
        let relatedOccurrences = store.occurrences.filter { $0.alarmId == alarm.id }
        var allIds = Set<UUID>()
        for occ in relatedOccurrences {
            allIds.formUnion(occ.systemAlarmIDs)
        }
        
        do {
            try await cancelAlarmsIfScheduled(ids: allIds)
            for occ in relatedOccurrences {
                notifications.cancelNotifications(for: occ.id)
                try store.removeOccurrence(id: occ.id)
            }
        } catch {
            // NUNCA apagar IDs enquanto cancel falha!
            throw SchedulerError.cancellationFailed("Falha ao cancelar alarmes no AlarmKit: \(error.localizedDescription)")
        }
        
        var disabled = alarm
        disabled.isEnabled = false
        try store.updateAlarm(disabled)
        print("[Scheduler] Alarme \(alarm.label) desativado.")
    }
    
    public func deleteAlarm(id: UUID) async throws {
        guard !inFlightAlarmIds.contains(id) else {
            throw SchedulerError.schedulingInProgress
        }
        inFlightAlarmIds.insert(id)
        isScheduling = true
        defer {
            inFlightAlarmIds.remove(id)
            isScheduling = false
        }
        
        let relatedOccurrences = store.occurrences.filter { $0.alarmId == id }
        var allIds = Set<UUID>()
        for occ in relatedOccurrences {
            allIds.formUnion(occ.systemAlarmIDs)
        }
        
        do {
            try await cancelAlarmsIfScheduled(ids: allIds)
            for occ in relatedOccurrences {
                notifications.cancelNotifications(for: occ.id)
                try store.removeOccurrence(id: occ.id)
            }
        } catch {
            // Nunca apagar IDs enquanto cancel falha
            throw SchedulerError.cancellationFailed("Falha ao cancelar ocorrências antes da eliminação: \(error.localizedDescription)")
        }
        try store.deleteAlarm(id: id)
    }
    
    // MARK: - Ciclo da Missão e Transição para Wake Up Check
    
    /// Chamado quando o utilizador conclui com sucesso a missão de despertar
    public func completeMission(for occurrenceId: UUID) async throws {
        guard var occurrence = store.occurrence(for: occurrenceId),
              let alarm = store.alarm(for: occurrence.alarmId) else {
            throw SchedulerError.occurrenceNotFound
        }
        
        guard !inFlightAlarmIds.contains(alarm.id) else {
            throw SchedulerError.schedulingInProgress
        }
        inFlightAlarmIds.insert(alarm.id)
        defer {
            inFlightAlarmIds.remove(alarm.id)
        }

        guard occurrence.status != .completed else { return }
        guard occurrence.status == .ringing || occurrence.status == .missionPending || occurrence.status == .wakeUpCheckPending else {
            throw SchedulerError.occurrenceNotFound
        }
        
        if alarm.isWakeUpCheckEnabled {
            let delaySeconds = Double(alarm.wakeUpCheckDelayMinutes * 60)
            let countdownSeconds = Double(alarm.wakeUpCheckCountdownSeconds)
            
            // A rescue that already fired belongs to the previous check cycle.
            let needsNewWindow = occurrence.wakeUpCheckDeadline.map { $0 <= Date() } ?? true
            if needsNewWindow, let oldID = occurrence.wakeUpCheckRescueId {
                var cleanup = Set(occurrence.pendingCleanupAlarmIDs ?? [])
                cleanup.insert(oldID)
                occurrence.pendingCleanupAlarmIDs = Array(cleanup)
            }
            let checkAt = needsNewWindow ? Date().addingTimeInterval(delaySeconds)
                : (occurrence.wakeUpCheckAt ?? Date().addingTimeInterval(delaySeconds))
            let deadline = needsNewWindow ? checkAt.addingTimeInterval(countdownSeconds)
                : (occurrence.wakeUpCheckDeadline ?? checkAt.addingTimeInterval(countdownSeconds))
            let checkRescueId = needsNewWindow ? UUID() : (occurrence.wakeUpCheckRescueId ?? UUID())
            
            // 1. Persistir checkAt/deadline/ID como transição pending ANTES do efeito no SO
            occurrence.wakeUpCheckRescueId = checkRescueId
            occurrence.wakeUpCheckAt = checkAt
            occurrence.wakeUpCheckDeadline = deadline
            try store.saveOccurrence(occurrence)
            
            // 2. Agendar resgate novo do Wake Up Check
            do {
                // Retrying a persisted transition reuses its already scheduled rescue.
                if !(try alarmKit.scheduledAlarmIDs()).contains(checkRescueId) {
                    try await alarmKit.scheduleAlarm(
                        id: checkRescueId,
                        title: "🚨 RESGATE WAKE UP CHECK: Voltou a dormir?",
                        fireDate: deadline,
                        soundName: occurrence.soundName,
                        isRescue: true
                    )
                }
            } catch {
                // Se schedule falha, manter missão/resgate original ativo e propagar erro
                throw SchedulerError.schedulingFailed("Falha ao pré-agendar resgate do Wake Up Check: \(error.localizedDescription)")
            }
            
            // Only stop the current system alert after the new protection exists.
            do {
                try await alarmKit.stopAlarmIfAlerting(id: occurrence.primaryAlarmKitId)
                var cleanup = Set(occurrence.pendingCleanupAlarmIDs ?? [])
                cleanup.insert(occurrence.rescueAlarmKitId)
                cleanup.remove(checkRescueId)
                try await cancelAlarmsIfScheduled(ids: cleanup)
            } catch {
                throw SchedulerError.cancellationFailed("Wake Up Check agendado, mas falha ao cancelar resgate anterior: \(error.localizedDescription)")
            }

            occurrence.status = .wakeUpCheckPending
            occurrence.pendingCleanupAlarmIDs = nil
            try store.saveOccurrence(occurrence)
            
            // Agendar notificação normal amigável no momento checkAt
            notifications.scheduleWakeUpCheckNotification(
                occurrenceId: occurrence.id,
                alarmId: alarm.id,
                fireDate: checkAt
            )
            print("[Scheduler] Wake Up Check agendado para \(checkAt). Deadline absoluto: \(deadline)")
        } else {
            // Finalizado sem Wake Up Check: cancelar resgate imediato
            do {
                try await alarmKit.stopAlarmIfAlerting(id: occurrence.primaryAlarmKitId)
                try await cancelAlarmsIfScheduled(ids: occurrence.systemAlarmIDs.subtracting([occurrence.primaryAlarmKitId]))
            } catch {
                throw SchedulerError.cancellationFailed("Falha ao cancelar resgate da missão: \(error.localizedDescription)")
            }
            
            occurrence.status = .completed
            
            // Se for recorrente, o principal já repete semanalmente no SO!
            // Renovar só próximo resgate com novo occurrence persistido ANTES schedule
            if !alarm.repeatDays.isEmpty {
                try store.saveOccurrence(occurrence)
                await renewRescueAfterCompletion(alarm, occurrence: occurrence)
            } else {
                var disabled = alarm
                disabled.isEnabled = false
                try store.commitAlarm(disabled, occurrence: occurrence)
            }
        }
    }
    
    /// Confirma o Wake Up Check se estiver dentro da janela [checkAt, deadline] e cancela o resgate
    public func confirmWakeUpCheck(for occurrenceId: UUID) async throws {
        guard var occurrence = store.occurrence(for: occurrenceId) else {
            throw SchedulerError.occurrenceNotFound
        }
        
        guard !inFlightAlarmIds.contains(occurrence.alarmId) else {
            throw SchedulerError.schedulingInProgress
        }
        inFlightAlarmIds.insert(occurrence.alarmId)
        defer {
            inFlightAlarmIds.remove(occurrence.alarmId)
        }

        guard occurrence.status != .completed else { return }
        guard occurrence.status == .wakeUpCheckPending else { throw SchedulerError.occurrenceNotFound }
        
        guard let checkAt = occurrence.wakeUpCheckAt,
              let deadline = occurrence.wakeUpCheckDeadline else {
            throw SchedulerError.occurrenceNotFound
        }
        
        let now = Date()
        if now < checkAt {
            throw SchedulerError.wakeUpCheckTooEarly
        }
        if now > deadline {
            throw SchedulerError.wakeUpCheckExpired
        }
        
        // Cancelar alarme de resgate do check e aguardar confirmação
        try await cancelAlarmsIfScheduled(ids: occurrence.systemAlarmIDs.subtracting([occurrence.primaryAlarmKitId]))
        notifications.cancelWakeUpCheckNotification(occurrenceId: occurrenceId)
        
        occurrence.status = .completed
        
        // Se for recorrente, renovar resgate para a próxima ocorrência semanal sem recriar o principal
        if let alarm = store.alarm(for: occurrence.alarmId) {
            if !alarm.repeatDays.isEmpty {
                try store.saveOccurrence(occurrence)
                await renewRescueAfterCompletion(alarm, occurrence: occurrence)
            } else {
                var disabled = alarm
                disabled.isEnabled = false
                try store.commitAlarm(disabled, occurrence: occurrence)
            }
        } else {
            try store.saveOccurrence(occurrence)
        }
        print("[Scheduler] Wake Up Check confirmado! Alarme de resgate cancelado com sucesso.")
    }
    
    /// Chamado quando o tempo do Wake Up Check expira sem confirmação
    public func failWakeUpCheck(for occurrenceId: UUID) {
        if var occurrence = store.occurrence(for: occurrenceId) {
            occurrence.status = .ringing
            do { try store.saveOccurrence(occurrence) }
            catch { activeErrorMessage = error.localizedDescription }
        }
    }
    
    // MARK: - Renovação de Resgate para Alarmes Recorrentes
    
    private func renewRescueAfterCompletion(_ alarm: Alarm, occurrence: OccurrenceState) async {
        do {
            try await scheduleNextRescueForRecurringAlarm(alarm, completed: occurrence)
        } catch {
            // The current mission is finished; a future rescue failure must not reopen it.
            activeErrorMessage = "Missão concluída, mas falta preparar o próximo resgate: \(error.localizedDescription)"
        }
    }

    private func scheduleNextRescueForRecurringAlarm(_ alarm: Alarm, completed: OccurrenceState) async throws {
        guard (try alarmKit.scheduledAlarmIDs()).contains(completed.primaryAlarmKitId) else {
            throw SchedulerError.schedulingFailed("O alarme semanal não está registado no sistema; volte a ativá-lo.")
        }
        let reference = max(Date(), completed.scheduledFireDate.addingTimeInterval(1))
        let nextFireDate = alarm.nextFireDate(after: reference)
        let nextRescueDate = nextFireDate.addingTimeInterval(180)
        let nextRescueId = UUID()
        let nextOccurrenceId = UUID()
        
        let existing = store.occurrences.first(where: {
            $0.alarmId == alarm.id && $0.scheduledFireDate == nextFireDate &&
            ($0.status == .scheduled || $0.status == .failed)
        })
        let nextOccurrence = existing ?? OccurrenceState(
            id: nextOccurrenceId,
            alarmId: alarm.id,
            scheduledFireDate: nextFireDate,
            primaryAlarmKitId: completed.primaryAlarmKitId,
            rescueAlarmKitId: nextRescueId,
            missionType: alarm.missionType,
            registeredBarcode: alarm.registeredBarcode,
            mathDifficulty: alarm.mathDifficulty,
            mathProblemsCount: alarm.mathProblemsCount,
            soundName: alarm.soundName,
            status: .scheduled
        )
        // Persistir ocorrência ANTES do schedule
        try store.saveOccurrence(nextOccurrence)
        
        do {
            if !(try alarmKit.scheduledAlarmIDs()).contains(nextOccurrence.rescueAlarmKitId) {
                try await alarmKit.scheduleAlarm(
                    id: nextOccurrence.rescueAlarmKitId,
                    title: "🚨 RESGATE: \(alarm.label)",
                    fireDate: nextRescueDate,
                    soundName: alarm.soundName,
                    isRescue: true
                )
            }
            if nextOccurrence.status != .scheduled {
                try store.updateOccurrenceStatus(id: nextOccurrence.id, status: .scheduled)
            }
            print("[Scheduler] Próximo resgate semanal agendado para \(nextRescueDate)")
        } catch {
            var failedOcc = nextOccurrence
            failedOcc.status = .failed
            try? store.saveOccurrence(failedOcc)
            activeErrorMessage = "Falha ao agendar resgate da próxima ocorrência: \(error.localizedDescription)"
            throw SchedulerError.schedulingFailed("Falha ao agendar resgate da próxima ocorrência recorrente: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Reconciliação no Foreground
    
    public func reconcileInForeground() {
        // 1. Autorização revogada
        if alarmKit.authorizationStatus == .denied {
            activeErrorMessage = "A permissão de AlarmKit foi revogada nas Definições do iOS."
        }
        
        // 2. Reconciliação de Wake Up Check expirado enquanto o app esteve em segundo plano
        if let pendingCheck = store.getPendingWakeUpCheckOccurrence(),
           let deadline = pendingCheck.wakeUpCheckDeadline {
            if Date() > deadline {
                failWakeUpCheck(for: pendingCheck.id)
            }
        }

        guard !isRecoveringChanges else { return }
        isRecoveringChanges = true
        Task { @MainActor in
            defer { isRecoveringChanges = false }
            let pendingChanges = store.occurrences.filter {
                $0.status == .preparing || $0.status == .cleanupPending
            }
            for pending in pendingChanges where !inFlightAlarmIds.contains(pending.alarmId) {
                inFlightAlarmIds.insert(pending.alarmId)
                do {
                    let previousOccurrences = store.occurrences.filter {
                        $0.alarmId == pending.alarmId && $0.id != pending.id &&
                        $0.status != .preparing && $0.status != .cleanupPending
                    }
                    var previous = store.alarm(for: pending.alarmId)
                    if let wasEnabled = pending.replacementWasEnabled { previous?.isEnabled = wasEnabled }
                    try await restorePreviousSchedules(previous, occurrences: previousOccurrences,
                        ids: Set(pending.replacementAlarmIDs ?? []))
                    try await cancelAlarmsIfScheduled(ids: pending.systemAlarmIDs)
                    try store.removeOccurrence(id: pending.id)
                    if var restored = previous {
                        let live = try alarmKit.scheduledAlarmIDs()
                        restored.isEnabled = restored.isEnabled && previousOccurrences.contains {
                            live.contains($0.primaryAlarmKitId)
                        }
                        try store.updateAlarm(restored)
                    }
                    activeErrorMessage = "Uma edição interrompida foi recuperada. Confirme a configuração antes de voltar a ativar o alarme."
                } catch {
                    activeErrorMessage = "Há uma edição por recuperar: \(error.localizedDescription). Tente novamente ou desative o alarme."
                }
                inFlightAlarmIds.remove(pending.alarmId)
            }

            // Retry missing future rescues without recreating the weekly primary.
            for alarm in store.alarms where alarm.isEnabled && !alarm.repeatDays.isEmpty && !inFlightAlarmIds.contains(alarm.id) {
                let related = store.occurrences.filter { $0.alarmId == alarm.id }
                guard !related.contains(where: {
                    $0.status == .ringing || $0.status == .missionPending || $0.status == .wakeUpCheckPending ||
                    $0.status == .preparing || $0.status == .cleanupPending
                }), let completed = related.filter({ $0.status == .completed })
                    .max(by: { $0.scheduledFireDate < $1.scheduledFireDate }) else { continue }
                inFlightAlarmIds.insert(alarm.id)
                await renewRescueAfterCompletion(alarm, occurrence: completed)
                inFlightAlarmIds.remove(alarm.id)
            }
        }
    }
}
