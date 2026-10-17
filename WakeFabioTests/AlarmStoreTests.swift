import XCTest
@testable import WakeFabio

final class AlarmStoreTests: XCTestCase {
    
    var tempDirectory: URL!
    var tempStoreURL: URL!
    
    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("WakeFabioTests_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        tempStoreURL = tempDirectory.appendingPathComponent("store.json")
    }
    
    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDirectory)
        super.tearDown()
    }
    
    func testStoreInitialLoadCreatesDefault() throws {
        let store = AlarmStore(customStoreURL: tempStoreURL)
        XCTAssertFalse(store.alarms.isEmpty)
        XCTAssertEqual(store.alarms.first?.label, "Despertar Principal")
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempStoreURL.path))
    }
    
    func testAddUpdateDeleteAlarm() throws {
        let store = AlarmStore(customStoreURL: tempStoreURL)
        let initialCount = store.alarms.count
        
        let newAlarm = Alarm(
            time: Date(),
            isEnabled: false,
            label: "Treino Matinal",
            missionType: .barcode,
            registeredBarcode: "TEST-QR-12345"
        )
        
        try store.addAlarm(newAlarm)
        XCTAssertEqual(store.alarms.count, initialCount + 1)
        XCTAssertNotNil(store.alarm(for: newAlarm.id))
        
        var modified = newAlarm
        modified.label = "Treino Modificado"
        try store.updateAlarm(modified)
        XCTAssertEqual(store.alarm(for: newAlarm.id)?.label, "Treino Modificado")
        
        try store.deleteAlarm(id: newAlarm.id)
        XCTAssertNil(store.alarm(for: newAlarm.id))
    }
    
    func testOccurrenceLifecyclePersistence() throws {
        let store = AlarmStore(customStoreURL: tempStoreURL)
        let alarmId = UUID()
        let occId = UUID()
        
        let occ = OccurrenceState(
            id: occId,
            alarmId: alarmId,
            scheduledFireDate: Date(),
            missionType: .barcode,
            registeredBarcode: "BARCODE-XYZ",
            status: .scheduled
        )
        
        try store.saveOccurrence(occ)
        XCTAssertEqual(store.occurrence(for: occId)?.status, .scheduled)
        
        try store.updateOccurrenceStatus(id: occId, status: .missionPending)
        XCTAssertEqual(store.occurrence(for: occId)?.status, .missionPending)
        
        // Simular nova leitura a partir do disco
        let reloadedStore = AlarmStore(customStoreURL: tempStoreURL)
        XCTAssertEqual(reloadedStore.occurrence(for: occId)?.status, .missionPending)
    }
    
    func testCorruptedDataBlocksSubsequentWrites() throws {
        // Gravar lixo no ficheiro de armazenamento
        let garbage = "{ invalid json content: corrupted 12345".data(using: .utf8)!
        try garbage.write(to: tempStoreURL)
        
        let store = AlarmStore(customStoreURL: tempStoreURL)
        XCTAssertTrue(store.isWriteBlocked, "A gravação deve ser bloqueada quando o ficheiro está corrompido")
        XCTAssertNotNil(store.lastErrorMessage)
        
        let newAlarm = Alarm(
            time: Date(),
            isEnabled: false,
            label: "Tentativa de Escrita",
            missionType: .math
        )
        
        XCTAssertThrowsError(try store.addAlarm(newAlarm)) { error in
            guard case StoreError.corruptedData = error else {
                XCTFail("Deveria lançar StoreError.corruptedData, obteve: \(error)")
                return
            }
        }
        
        // Verifica se a cópia de segurança de corrupção foi criada
        let files = try FileManager.default.contentsOfDirectory(at: tempDirectory, includingPropertiesForKeys: nil)
        let backupFiles = files.filter { $0.lastPathComponent.contains("corrupted") }
        XCTAssertFalse(backupFiles.isEmpty, "Deve preservar backup do ficheiro corrompido")
    }
    
    func testUnknownSchemaVersionBlocksWrites() throws {
        let unknownSchemaJson = """
        {
            "schemaVersion": 99,
            "alarms": [],
            "occurrences": []
        }
        """.data(using: .utf8)!
        try unknownSchemaJson.write(to: tempStoreURL)
        
        let store = AlarmStore(customStoreURL: tempStoreURL)
        XCTAssertTrue(store.isWriteBlocked, "Esquema futuro desconhecido deve bloquear gravações")
        
        let newAlarm = Alarm(time: Date(), isEnabled: false)
        XCTAssertThrowsError(try store.addAlarm(newAlarm))
    }
    
    func testAtomicConfigurationCommitRestoresBothCollectionsOnFailure() throws {
        let store = AlarmStore(customStoreURL: tempStoreURL)
        let original = store.alarms.first!
        let previous = OccurrenceState(alarmId: original.id, scheduledFireDate: Date(), missionType: .math)
        try store.saveOccurrence(previous)
        var edited = original
        edited.label = "Must not commit"
        let replacement = OccurrenceState(alarmId: original.id, scheduledFireDate: Date(), missionType: .math)
        // A directory at the file path forces the actual atomic disk write to fail.
        try FileManager.default.removeItem(at: tempStoreURL)
        try FileManager.default.createDirectory(at: tempStoreURL, withIntermediateDirectories: true)
        XCTAssertThrowsError(try store.commitAlarm(edited, occurrence: replacement))
        XCTAssertEqual(store.alarm(for: original.id), original)
        XCTAssertEqual(store.occurrences, [previous])
    }

    func testWriteFailureRestoresMemorySnapshot() throws {
        let store = AlarmStore(customStoreURL: tempStoreURL)
        let initialAlarms = store.alarms
        
        // Simula bloqueio de escrita
        let corruptedJson = "not json".data(using: .utf8)!
        try corruptedJson.write(to: tempStoreURL)
        let storeWithCorrupt = AlarmStore(customStoreURL: tempStoreURL)
        
        let countBefore = storeWithCorrupt.alarms.count
        let dummy = Alarm(time: Date(), isEnabled: false)
        
        do {
            try storeWithCorrupt.addAlarm(dummy)
            XCTFail("Deveria ter falhado a escrita")
        } catch {
            // Verifica que a memória não manteve o alarme rejeitado
            XCTAssertEqual(storeWithCorrupt.alarms.count, countBefore)
        }
    }
}
