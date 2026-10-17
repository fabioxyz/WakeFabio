import Foundation

public enum OccurrenceStatus: String, Codable, Equatable {
    case preparing = "A preparar agendamento"
    case scheduled = "Agendado"
    case ringing = "Tocando"
    case missionPending = "Missão Pendente"
    case wakeUpCheckPending = "Wake Up Check Pendente"
    case completed = "Concluído com Sucesso"
    case dismissed = "Ignorado"
    case cancelled = "Cancelado"
    case failed = "Falha de Agendamento"
    case cleanupPending = "Limpeza Pendente"
}

public struct OccurrenceState: Identifiable, Codable, Equatable {
    public var id: UUID // ID único da ocorrência
    public var alarmId: UUID // ID do alarme mestre
    public var scheduledFireDate: Date
    public var primaryAlarmKitId: UUID // ID estável do alarme principal no AlarmKit
    public var rescueAlarmKitId: UUID // ID estável do alarme de resgate (safety) no AlarmKit
    
    // Wake Up Check state
    public var wakeUpCheckRescueId: UUID? // ID do alarme de resgate do Wake Up Check
    public var wakeUpCheckAt: Date? // Timestamp quando o usuário deve ser notificado
    public var wakeUpCheckDeadline: Date? // Timestamp absoluto final para confirmação
    // Optional for compatibility with stores written before recovery was added.
    public var pendingCleanupAlarmIDs: [UUID]? = nil
    public var replacementAlarmIDs: [UUID]? = nil
    public var replacementWasEnabled: Bool? = nil

    public var systemAlarmIDs: Set<UUID> {
        var ids: Set<UUID> = [primaryAlarmKitId, rescueAlarmKitId]
        if let id = wakeUpCheckRescueId { ids.insert(id) }
        ids.formUnion(pendingCleanupAlarmIDs ?? [])
        return ids
    }
    
    // Dados da missão no momento do agendamento (isolamento contra edições posteriores durante disparo)
    public var missionType: MissionType
    public var registeredBarcode: String?
    public var mathDifficulty: MathDifficulty
    public var mathProblemsCount: Int
    public var soundName: String
    
    public var status: OccurrenceStatus
    public var createdAt: Date
    public var updatedAt: Date
    
    public init(
        id: UUID = UUID(),
        alarmId: UUID,
        scheduledFireDate: Date,
        primaryAlarmKitId: UUID = UUID(),
        rescueAlarmKitId: UUID = UUID(),
        wakeUpCheckRescueId: UUID? = nil,
        wakeUpCheckAt: Date? = nil,
        wakeUpCheckDeadline: Date? = nil,
        missionType: MissionType,
        registeredBarcode: String? = nil,
        mathDifficulty: MathDifficulty = .medium,
        mathProblemsCount: Int = 3,
        soundName: String = "loud1.mp3",
        status: OccurrenceStatus = .scheduled,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.alarmId = alarmId
        self.scheduledFireDate = scheduledFireDate
        self.primaryAlarmKitId = primaryAlarmKitId
        self.rescueAlarmKitId = rescueAlarmKitId
        self.wakeUpCheckRescueId = wakeUpCheckRescueId
        self.wakeUpCheckAt = wakeUpCheckAt
        self.wakeUpCheckDeadline = wakeUpCheckDeadline
        self.missionType = missionType
        self.registeredBarcode = registeredBarcode
        self.mathDifficulty = mathDifficulty
        self.mathProblemsCount = mathProblemsCount
        self.soundName = soundName
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
