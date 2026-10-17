import Foundation
import Combine

public struct StoreEnvelope: Codable {
    public var schemaVersion: Int
    public var alarms: [Alarm]
    public var occurrences: [OccurrenceState]
    
    public init(schemaVersion: Int = 1, alarms: [Alarm] = [], occurrences: [OccurrenceState] = []) {
        self.schemaVersion = schemaVersion
        self.alarms = alarms
        self.occurrences = occurrences
    }
}

public enum StoreError: LocalizedError {
    case writeFailed(String)
    case corruptedData(String)
    case directoryCreationFailed(String)
    
    public var errorDescription: String? {
        switch self {
        case .writeFailed(let reason):
            return "Erro ao gravar dados no disco: \(reason)"
        case .corruptedData(let reason):
            return "Ficheiro corrompido preservado em cópia de segurança: \(reason)"
        case .directoryCreationFailed(let reason):
            return "Falha ao criar directoria de armazenamento: \(reason)"
        }
    }
}

public final class AlarmStore: ObservableObject {
    public static let shared = AlarmStore()
    
    @Published public private(set) var alarms: [Alarm] = []
    @Published public private(set) var occurrences: [OccurrenceState] = []
    @Published public var lastErrorMessage: String? = nil
    @Published public private(set) var isWriteBlocked: Bool = false
    
    private let fileManager: FileManager
    public let storeURL: URL
    private let queue = DispatchQueue(label: "com.wakefabio.alarmstore", qos: .userInitiated)
    
    public init(fileManager: FileManager = .default, customStoreURL: URL? = nil) {
        self.fileManager = fileManager
        
        if let customURL = customStoreURL {
            self.storeURL = customURL
        } else {
            let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? fileManager.temporaryDirectory
            let folder = appSupport.appendingPathComponent("WakeFabio", isDirectory: true)
            
            if !fileManager.fileExists(atPath: folder.path) {
                try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: nil)
            }
            self.storeURL = folder.appendingPathComponent("wakefabio_store.json")
        }
        
        load()
    }
    
    // MARK: - Persistência Atómica e Versionada
    
    public func load() {
        queue.sync {
            guard fileManager.fileExists(atPath: storeURL.path) else {
                // Primeira execução: inicia com alarme padrão desligado
                let defaultAlarm = Alarm(
                    time: Calendar.current.date(bySettingHour: 7, minute: 0, second: 0, of: Date()) ?? Date(),
                    isEnabled: false,
                    label: "Despertar Principal",
                    repeatDays: [2, 3, 4, 5, 6], // Seg a Sex
                    soundName: "loud1.mp3",
                    missionType: .barcode,
                    registeredBarcode: nil,
                    isWakeUpCheckEnabled: true,
                    wakeUpCheckDelayMinutes: 5,
                    wakeUpCheckCountdownSeconds: 100
                )
                self.alarms = [defaultAlarm]
                self.occurrences = []
                self.isWriteBlocked = false
                try? self.saveInternal()
                return
            }
            
            do {
                let data = try Data(contentsOf: storeURL)
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                
                let envelope = try decoder.decode(StoreEnvelope.self, from: data)
                if envelope.schemaVersion > 1 {
                    self.isWriteBlocked = true
                    let msg = "Versão de esquema desconhecida (\(envelope.schemaVersion)). Gravação desativada para preservar dados."
                    self.lastErrorMessage = msg
                    print("[AlarmStore] \(msg)")
                    return
                }
                
                self.alarms = envelope.alarms
                self.occurrences = envelope.occurrences
                self.isWriteBlocked = false
                self.lastErrorMessage = nil
            } catch {
                print("[AlarmStore] Ficheiro corrompido detectado ao decodificar: \(error)")
                self.isWriteBlocked = true
                let timestamp = Int(Date().timeIntervalSince1970)
                let backupURL = storeURL.deletingPathExtension().appendingPathExtension("corrupted.\(timestamp).json")
                if (try? fileManager.copyItem(at: storeURL, to: backupURL)) != nil {
                    print("[AlarmStore] Ficheiro corrompido preservado em: \(backupURL.path)")
                }
                self.lastErrorMessage = "Loja de dados corrompida. Backup preservado em \(backupURL.lastPathComponent). Gravação desativada."
                // NÃO sobrescrever o ficheiro em disco com dados vazios silenciosamente!
            }
        }
    }
    
    public func save() throws {
        try queue.sync {
            try saveInternal()
        }
    }
    
    private func saveInternal() throws {
        guard !isWriteBlocked else {
            throw StoreError.corruptedData("Gravação bloqueada: ficheiro original corrompido ou versão desconhecida preservada.")
        }
        
        let envelope = StoreEnvelope(
            schemaVersion: 1,
            alarms: self.alarms,
            occurrences: self.occurrences
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        
        let data: Data
        do {
            data = try encoder.encode(envelope)
        } catch {
            let msg = "Falha ao codificar loja: \(error.localizedDescription)"
            self.lastErrorMessage = msg
            throw StoreError.writeFailed(msg)
        }
        
        let parentDir = storeURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: parentDir.path) {
            do {
                try fileManager.createDirectory(at: parentDir, withIntermediateDirectories: true, attributes: nil)
            } catch {
                let msg = "Falha ao criar diretório pai: \(error.localizedDescription)"
                self.lastErrorMessage = msg
                throw StoreError.directoryCreationFailed(msg)
            }
        }
        
        // Escrita atómica para evitar corrupção em falhas de energia/crash
        do {
            try data.write(to: storeURL, options: .atomic)
            self.lastErrorMessage = nil
        } catch {
            let msg = "Erro de escrita atómica: \(error.localizedDescription)"
            self.lastErrorMessage = msg
            throw StoreError.writeFailed(msg)
        }
    }
    
    // MARK: - Gestão de Alarmes (CRUD)

    /// Commit configuration and its confirmed occurrence in one disk write.
    public func commitAlarm(_ alarm: Alarm, occurrence: OccurrenceState) throws {
        try queue.sync {
            let previousAlarms = alarms
            let previousOccurrences = occurrences
            var updated = alarm
            updated.updatedAt = Date()
            if let index = alarms.firstIndex(where: { $0.id == alarm.id }) {
                alarms[index] = updated
            } else {
                alarms.append(updated)
            }
            occurrences.removeAll(where: { $0.alarmId == alarm.id })
            occurrences.append(occurrence)
            do {
                try saveInternal()
            } catch {
                alarms = previousAlarms
                occurrences = previousOccurrences
                throw error
            }
        }
    }
    
    public func addAlarm(_ alarm: Alarm) throws {
        try queue.sync {
            let previousAlarms = self.alarms
            var updated = alarm
            updated.updatedAt = Date()
            self.alarms.append(updated)
            do {
                try self.saveInternal()
            } catch {
                self.alarms = previousAlarms
                throw error
            }
        }
        DispatchQueue.main.async { self.objectWillChange.send() }
    }
    
    public func updateAlarm(_ alarm: Alarm) throws {
        try queue.sync {
            let previousAlarms = self.alarms
            if let index = self.alarms.firstIndex(where: { $0.id == alarm.id }) {
                var updated = alarm
                updated.updatedAt = Date()
                self.alarms[index] = updated
                do {
                    try self.saveInternal()
                } catch {
                    self.alarms = previousAlarms
                    throw error
                }
            }
        }
        DispatchQueue.main.async { self.objectWillChange.send() }
    }
    
    public func deleteAlarm(id: UUID) throws {
        try queue.sync {
            let previousAlarms = self.alarms
            let previousOccurrences = self.occurrences
            self.alarms.removeAll(where: { $0.id == id })
            self.occurrences.removeAll(where: { $0.alarmId == id })
            do {
                try self.saveInternal()
            } catch {
                self.alarms = previousAlarms
                self.occurrences = previousOccurrences
                throw error
            }
        }
        DispatchQueue.main.async { self.objectWillChange.send() }
    }
    
    public func alarm(for id: UUID) -> Alarm? {
        queue.sync {
            self.alarms.first(where: { $0.id == id })
        }
    }
    
    // MARK: - Gestão de Ocorrências (Runtime State)
    
    public func saveOccurrence(_ occurrence: OccurrenceState) throws {
        try queue.sync {
            let previousOccurrences = self.occurrences
            if let index = self.occurrences.firstIndex(where: { $0.id == occurrence.id }) {
                var updated = occurrence
                updated.updatedAt = Date()
                self.occurrences[index] = updated
            } else {
                self.occurrences.append(occurrence)
            }
            do {
                try self.saveInternal()
            } catch {
                self.occurrences = previousOccurrences
                throw error
            }
        }
        DispatchQueue.main.async { self.objectWillChange.send() }
    }
    
    public func occurrence(for id: UUID) -> OccurrenceState? {
        queue.sync {
            self.occurrences.first(where: { $0.id == id })
        }
    }
    
    public func activeOccurrence(forAlarmId alarmId: UUID) -> OccurrenceState? {
        queue.sync {
            self.occurrences.first(where: { $0.alarmId == alarmId && $0.status != .completed && $0.status != .cancelled && $0.status != .failed })
        }
    }
    
    public func getPendingMissionOccurrence() -> OccurrenceState? {
        queue.sync {
            self.occurrences
                .filter { $0.status == .ringing || $0.status == .missionPending }
                .sorted { $0.scheduledFireDate < $1.scheduledFireDate }
                .first
        }
    }
    
    public func getPendingWakeUpCheckOccurrence() -> OccurrenceState? {
        queue.sync {
            self.occurrences
                .filter { $0.status == .wakeUpCheckPending }
                .sorted { ($0.wakeUpCheckAt ?? $0.scheduledFireDate) < ($1.wakeUpCheckAt ?? $1.scheduledFireDate) }
                .first
        }
    }
    
    public func getEarliestPendingOccurrence() -> OccurrenceState? {
        queue.sync {
            self.occurrences
                .filter { $0.status == .ringing || $0.status == .missionPending || $0.status == .wakeUpCheckPending }
                .sorted { $0.scheduledFireDate < $1.scheduledFireDate }
                .first
        }
    }
    
    public func updateOccurrenceStatus(id: UUID, status: OccurrenceStatus) throws {
        try queue.sync {
            let previousOccurrences = self.occurrences
            if let index = self.occurrences.firstIndex(where: { $0.id == id }) {
                self.occurrences[index].status = status
                self.occurrences[index].updatedAt = Date()
                do {
                    try self.saveInternal()
                } catch {
                    self.occurrences = previousOccurrences
                    throw error
                }
            }
        }
        DispatchQueue.main.async { self.objectWillChange.send() }
    }
    
    public func removeOccurrence(id: UUID) throws {
        try queue.sync {
            let previousOccurrences = self.occurrences
            self.occurrences.removeAll(where: { $0.id == id })
            do {
                try self.saveInternal()
            } catch {
                self.occurrences = previousOccurrences
                throw error
            }
        }
        DispatchQueue.main.async { self.objectWillChange.send() }
    }
    
    public func clearOccurrences(forAlarmId alarmId: UUID) throws {
        try queue.sync {
            let previousOccurrences = self.occurrences
            self.occurrences.removeAll(where: { $0.alarmId == alarmId })
            do {
                try self.saveInternal()
            } catch {
                self.occurrences = previousOccurrences
                throw error
            }
        }
        DispatchQueue.main.async { self.objectWillChange.send() }
    }
}
