import XCTest
import Combine
@testable import WakeFabio

final class MockAlarmKitScheduler: AlarmKitSchedulingProtocol {
    var authorizationStatus: AlarmAuthorizationStatus = .authorized
    var scheduledAlarms: [UUID: (title: String, fireDate: Date, isRescue: Bool)] = [:]
    var scheduledRepeatDays: [UUID: Set<Int>] = [:]
    var cancelledAlarms: Set<UUID> = []
    var alertingAlarmIDs: Set<UUID> = []
    var stoppedAlarmIDs: Set<UUID> = []
    var shouldFailOnStop = false
    var failCancellationOnceFor: Set<UUID> = []
    
    var shouldFailOnRescue: Bool = false
    var shouldFailOnPrimary: Bool = false
    var shouldFailOnCancel: Bool = false
    
    func requestAuthorization() async -> Bool {
        authorizationStatus == .authorized
    }
    
    func scheduleAlarm(id: UUID, title: String, fireDate: Date, soundName: String, isRescue: Bool, repeatDays: Set<Int>) async throws {
        if isRescue && shouldFailOnRescue {
            throw NSError(domain: "MockAlarmKit", code: -101, userInfo: [NSLocalizedDescriptionKey: "Simulated rescue failure"])
        }
        if !isRescue && shouldFailOnPrimary {
            throw NSError(domain: "MockAlarmKit", code: -102, userInfo: [NSLocalizedDescriptionKey: "Simulated primary failure"])
        }
        scheduledAlarms[id] = (title, fireDate, isRescue)
        scheduledRepeatDays[id] = repeatDays
    }
    
    func cancelAlarm(id: UUID) async throws {
        if shouldFailOnCancel || failCancellationOnceFor.remove(id) != nil {
            throw NSError(domain: "MockAlarmKit", code: -103, userInfo: [NSLocalizedDescriptionKey: "Simulated cancel failure"])
        }
        scheduledAlarms.removeValue(forKey: id)
        scheduledRepeatDays.removeValue(forKey: id)
        cancelledAlarms.insert(id)
        alertingAlarmIDs.remove(id)
    }
    
    func scheduledAlarmIDs() throws -> Set<UUID> {
        Set(scheduledAlarms.keys)
    }

    func stopAlarmIfAlerting(id: UUID) async throws {
        guard alertingAlarmIDs.contains(id) else { return }
        if shouldFailOnStop { throw NSError(domain: "MockAlarmKit", code: -104) }
        stoppedAlarmIDs.insert(id)
        alertingAlarmIDs.remove(id)
        if (scheduledRepeatDays[id] ?? []).isEmpty {
            scheduledAlarms.removeValue(forKey: id)
        }
    }
}

@MainActor
final class AlarmSchedulerTests: XCTestCase {
    
    var mockKit: MockAlarmKitScheduler!
    var tempDirectory: URL!
    var tempStoreURL: URL!
    var store: AlarmStore!
    var coordinator: AlarmSchedulerCoordinator!
    
    override func setUp() async throws {
        try await super.setUp()
        mockKit = MockAlarmKitScheduler()
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("SchedulerTests_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        tempStoreURL = tempDirectory.appendingPathComponent("store.json")
        store = AlarmStore(customStoreURL: tempStoreURL)
        coordinator = AlarmSchedulerCoordinator(alarmKit: mockKit, store: store)
    }
    
    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDirectory)
        try await super.tearDown()
    }
    
    func testBarcodeRequiredValidation() async throws {
        let alarmWithoutBarcode = Alarm(
            time: Date(),
            isEnabled: false,
            missionType: .barcode,
            registeredBarcode: nil
        )
        try store.addAlarm(alarmWithoutBarcode)
        
        do {
            try await coordinator.enableAlarm(alarmWithoutBarcode)
            XCTFail("Deveria ter lançado erro de barcode obrigatório")
        } catch SchedulerError.barcodeRequired {
            // Sucesso esperado
            XCTAssertFalse(store.alarm(for: alarmWithoutBarcode.id)?.isEnabled ?? true)
            XCTAssertEqual(mockKit.scheduledAlarms.count, 0)
        } catch {
            XCTFail("Erro inesperado: \(error)")
        }
    }
    
    func testSuccessfulAlarmSchedulingWithPreScheduledRescue() async throws {
        let alarm = Alarm(
            time: Date().addingTimeInterval(3600),
            isEnabled: false,
            repeatDays: [2, 4, 6],
            missionType: .barcode,
            registeredBarcode: "TEST-QR-VALIDO"
        )
        try store.addAlarm(alarm)
        
        try await coordinator.enableAlarm(alarm)
        
        XCTAssertTrue(store.alarm(for: alarm.id)?.isEnabled ?? false)
        XCTAssertEqual(mockKit.scheduledAlarms.count, 2, "Deveria ter agendado o principal E o resgate de segurança")
        
        let occurrence = store.activeOccurrence(forAlarmId: alarm.id)
        XCTAssertNotNil(occurrence)
        
        let primaryId = occurrence!.primaryAlarmKitId
        let rescueId = occurrence!.rescueAlarmKitId
        
        XCTAssertNotNil(mockKit.scheduledAlarms[primaryId])
        XCTAssertEqual(mockKit.scheduledAlarms[primaryId]?.isRescue, false)
        XCTAssertNotNil(mockKit.scheduledAlarms[rescueId])
        XCTAssertEqual(mockKit.scheduledAlarms[rescueId]?.isRescue, true)
        XCTAssertEqual(mockKit.scheduledRepeatDays[primaryId], Set([2, 4, 6]))
        XCTAssertEqual(mockKit.scheduledRepeatDays[rescueId], Set<Int>())
    }
    
    func testAtomicRollbackOnRescueFailure() async throws {
        mockKit.shouldFailOnRescue = true
        
        let alarm = Alarm(
            time: Date().addingTimeInterval(3600),
            isEnabled: false,
            missionType: .barcode,
            registeredBarcode: "TEST-QR-VALIDO"
        )
        try store.addAlarm(alarm)
        
        do {
            try await coordinator.enableAlarm(alarm)
            XCTFail("Deveria ter falhado e feito rollback")
        } catch SchedulerError.schedulingFailed {
            // Verifica que o rollback cancelou o alarme principal e manteve o alarme desativado
            XCTAssertFalse(store.alarm(for: alarm.id)?.isEnabled ?? true)
            XCTAssertEqual(mockKit.scheduledAlarms.count, 0, "Nenhum alarme deve ficar órfão no sistema")
        } catch {
            XCTFail("Erro inesperado: \(error)")
        }
    }
    
    func testCompleteMissionCancelsRescueAndSchedulesWakeUpCheck() async throws {
        let alarm = Alarm(
            time: Date().addingTimeInterval(3600),
            isEnabled: true,
            missionType: .barcode,
            registeredBarcode: "TEST-QR-VALIDO",
            isWakeUpCheckEnabled: true,
            wakeUpCheckDelayMinutes: 5,
            wakeUpCheckCountdownSeconds: 100
        )
        try store.addAlarm(alarm)
        
        let occId = UUID()
        let primaryId = UUID()
        let rescueId = UUID()
        
        let occ = OccurrenceState(
            id: occId,
            alarmId: alarm.id,
            scheduledFireDate: Date(),
            primaryAlarmKitId: primaryId,
            rescueAlarmKitId: rescueId,
            missionType: .barcode,
            registeredBarcode: "TEST-QR-VALIDO",
            status: .ringing
        )
        try store.saveOccurrence(occ)
        mockKit.scheduledAlarms[rescueId] = ("Resgate", Date(), true)
        
        try await coordinator.completeMission(for: occId)
        
        // 1. Resgate do disparo deve ter sido cancelado
        XCTAssertTrue(mockKit.cancelledAlarms.contains(rescueId))
        
        // 2. Ocorrência deve ter transitado para .wakeUpCheckPending
        let updatedOcc = store.occurrence(for: occId)
        XCTAssertEqual(updatedOcc?.status, .wakeUpCheckPending)
        XCTAssertNotNil(updatedOcc?.wakeUpCheckRescueId)
        XCTAssertNotNil(updatedOcc?.wakeUpCheckDeadline)
    }
    
    func testConfirmWakeUpCheckCancelsCheckRescue() async throws {
        let occId = UUID()
        let checkRescueId = UUID()
        
        let occ = OccurrenceState(
            id: occId,
            alarmId: UUID(),
            scheduledFireDate: Date(),
            primaryAlarmKitId: UUID(),
            rescueAlarmKitId: UUID(),
            wakeUpCheckRescueId: checkRescueId,
            wakeUpCheckAt: Date().addingTimeInterval(-60),
            wakeUpCheckDeadline: Date().addingTimeInterval(100),
            missionType: .barcode,
            status: .wakeUpCheckPending
        )
        try store.saveOccurrence(occ)
        mockKit.scheduledAlarms[checkRescueId] = ("Check Rescue", Date(), true)
        
        try await coordinator.confirmWakeUpCheck(for: occId)
        
        XCTAssertTrue(mockKit.cancelledAlarms.contains(checkRescueId))
        XCTAssertEqual(store.occurrence(for: occId)?.status, .completed)
    }
    
    func testConfirmWakeUpCheckRejectsEarlyCheck() async throws {
        let occId = UUID()
        let checkRescueId = UUID()
        
        let occ = OccurrenceState(
            id: occId,
            alarmId: UUID(),
            scheduledFireDate: Date(),
            primaryAlarmKitId: UUID(),
            rescueAlarmKitId: UUID(),
            wakeUpCheckRescueId: checkRescueId,
            wakeUpCheckAt: Date().addingTimeInterval(300), // Futuro: checagem ainda não começou!
            wakeUpCheckDeadline: Date().addingTimeInterval(400),
            missionType: .barcode,
            status: .wakeUpCheckPending
        )
        try store.saveOccurrence(occ)
        
        do {
            try await coordinator.confirmWakeUpCheck(for: occId)
            XCTFail("Deveria rejeitar confirmação prematura do Wake Up Check")
        } catch SchedulerError.wakeUpCheckTooEarly {
            // Rejeição correta
            XCTAssertEqual(store.occurrence(for: occId)?.status, .wakeUpCheckPending)
        } catch {
            XCTFail("Erro inesperado: \(error)")
        }
    }
    
    func testScheduleWakeUpCheckFailureKeepsMissionRescue() async throws {
        let alarm = Alarm(
            time: Date().addingTimeInterval(3600),
            isEnabled: true,
            missionType: .barcode,
            registeredBarcode: "TEST-QR-VALIDO",
            isWakeUpCheckEnabled: true,
            wakeUpCheckDelayMinutes: 5,
            wakeUpCheckCountdownSeconds: 100
        )
        try store.addAlarm(alarm)
        
        let occId = UUID()
        let primaryId = UUID()
        let rescueId = UUID()
        
        let occ = OccurrenceState(
            id: occId,
            alarmId: alarm.id,
            scheduledFireDate: Date(),
            primaryAlarmKitId: primaryId,
            rescueAlarmKitId: rescueId,
            missionType: .barcode,
            registeredBarcode: "TEST-QR-VALIDO",
            status: .ringing
        )
        try store.saveOccurrence(occ)
        mockKit.scheduledAlarms[rescueId] = ("Resgate Missão", Date(), true)
        
        // Simular falha ao agendar resgate do Wake Up Check
        mockKit.shouldFailOnRescue = true
        
        do {
            try await coordinator.completeMission(for: occId)
            XCTFail("Deveria falhar ao agendar check rescue")
        } catch SchedulerError.schedulingFailed {
            // Sucesso do teste: resgate original NÃO deve ter sido cancelado
            XCTAssertFalse(mockKit.cancelledAlarms.contains(rescueId))
            // Status não deve ser marcado como wakeUpCheckPending
            XCTAssertNotEqual(store.occurrence(for: occId)?.status, .wakeUpCheckPending)
        }
    }
    
    func testCancellationFailurePreservesOccurrenceIDs() async throws {
        let alarm = Alarm(
            time: Date().addingTimeInterval(3600),
            isEnabled: true,
            missionType: .math
        )
        try store.addAlarm(alarm)
        
        let occId = UUID()
        let primaryId = UUID()
        let rescueId = UUID()
        
        let occ = OccurrenceState(
            id: occId,
            alarmId: alarm.id,
            scheduledFireDate: Date(),
            primaryAlarmKitId: primaryId,
            rescueAlarmKitId: rescueId,
            missionType: .math,
            status: .scheduled
        )
        try store.saveOccurrence(occ)
        mockKit.scheduledAlarms[primaryId] = ("Principal", Date(), false)
        mockKit.scheduledAlarms[rescueId] = ("Resgate", Date(), true)
        
        // Simular falha ao cancelar no SO
        mockKit.shouldFailOnCancel = true
        
        do {
            try await coordinator.disableAlarm(alarm)
            XCTFail("Deveria ter falhado ao desativar")
        } catch SchedulerError.cancellationFailed {
            // Ocorrência e IDs não devem ser removidos se o SO falhou
            XCTAssertNotNil(store.occurrence(for: occId))
            XCTAssertEqual(store.occurrence(for: occId)?.primaryAlarmKitId, primaryId)
        }
    }
    
    func testDoubleEnableDoesNotDuplicate() async throws {
        let alarm = Alarm(
            time: Date().addingTimeInterval(3600),
            isEnabled: false,
            missionType: .math
        )
        try store.addAlarm(alarm)
        
        try await coordinator.enableAlarm(alarm)
        let firstOccurrences = store.occurrences.filter { $0.alarmId == alarm.id }
        XCTAssertEqual(firstOccurrences.count, 1)
        
        // Segunda ativação consecutiva deve substituir sem duplicar
        var activeAlarm = store.alarm(for: alarm.id)!
        try await coordinator.enableAlarm(activeAlarm)
        let secondOccurrences = store.occurrences.filter { $0.alarmId == alarm.id }
        XCTAssertEqual(secondOccurrences.count, 1, "Não deve haver duplicação de ocorrências ativas")
        XCTAssertEqual(mockKit.scheduledAlarms.count, 2, "Apenas 1 principal e 1 resgate agendados")
    }

    func testRemovingBarcodeCanBeSavedWithoutLeavingAnActiveQRAlarm() async throws {
        let original = Alarm(time: Date().addingTimeInterval(3600), missionType: .barcode, registeredBarcode: "REGISTERED")
        try store.addAlarm(original)
        try await coordinator.enableAlarm(original)
        var draft = try XCTUnwrap(store.alarm(for: original.id))
        draft.registeredBarcode = nil
        draft.isEnabled = false
        try await coordinator.saveAlarm(draft)
        XCTAssertNil(store.alarm(for: original.id)?.registeredBarcode)
        XCTAssertEqual(store.alarm(for: original.id)?.isEnabled, false)
        XCTAssertTrue(mockKit.scheduledAlarms.isEmpty)
        do {
            try await coordinator.enableAlarm(draft)
            XCTFail("QR alarms without a code must not be enabled")
        } catch { }
        XCTAssertTrue(mockKit.scheduledAlarms.isEmpty)
    }

    func testFailedEditPreservesOriginalConfigurationAndSchedules() async throws {
        let original = Alarm(time: Date().addingTimeInterval(3600), label: "Original", missionType: .math)
        try store.addAlarm(original)
        try await coordinator.enableAlarm(original)
        let originalIDs = Set(mockKit.scheduledAlarms.keys)
        var edited = store.alarm(for: original.id)!
        edited.label = "Edited"
        mockKit.shouldFailOnRescue = true
        do {
            try await coordinator.saveAlarm(edited)
            XCTFail("The replacement must fail.")
        } catch SchedulerError.schedulingFailed { }
        XCTAssertEqual(store.alarm(for: original.id)?.label, "Original")
        XCTAssertEqual(store.alarm(for: original.id)?.isEnabled, true)
        XCTAssertEqual(Set(mockKit.scheduledAlarms.keys), originalIDs)
        XCTAssertEqual(store.occurrences.filter { $0.alarmId == original.id }.count, 1)
    }

    func testPartialReplacementCancellationRestoresOriginalPair() async throws {
        let original = Alarm(time: Date().addingTimeInterval(3600), label: "Original", missionType: .math)
        try store.addAlarm(original)
        try await coordinator.enableAlarm(original)
        let previous = store.activeOccurrence(forAlarmId: original.id)!
        let originalIDs = Set(mockKit.scheduledAlarms.keys)
        var edited = store.alarm(for: original.id)!
        edited.label = "Edited"
        mockKit.failCancellationOnceFor = [previous.rescueAlarmKitId]
        do {
            try await coordinator.saveAlarm(edited)
            XCTFail("The failed cancellation must not commit the edit.")
        } catch SchedulerError.schedulingFailed { }
        XCTAssertEqual(store.alarm(for: original.id)?.label, "Original")
        XCTAssertEqual(Set(mockKit.scheduledAlarms.keys), originalIDs)
    }

    func testMissionStopsAlertWithoutCancellingWeeklyPrimary() async throws {
        let alarm = Alarm(time: Date().addingTimeInterval(3600), repeatDays: [2, 4, 6],
            missionType: .math, isWakeUpCheckEnabled: false)
        try store.addAlarm(alarm)
        try await coordinator.enableAlarm(alarm)
        let occurrence = store.activeOccurrence(forAlarmId: alarm.id)!
        try store.updateOccurrenceStatus(id: occurrence.id, status: .missionPending)
        mockKit.alertingAlarmIDs.insert(occurrence.primaryAlarmKitId)
        try await coordinator.completeMission(for: occurrence.id)
        XCTAssertTrue(mockKit.stoppedAlarmIDs.contains(occurrence.primaryAlarmKitId))
        XCTAssertFalse(mockKit.cancelledAlarms.contains(occurrence.primaryAlarmKitId))
        XCTAssertNotNil(mockKit.scheduledAlarms[occurrence.primaryAlarmKitId])
        let count = mockKit.scheduledAlarms.count
        try await coordinator.completeMission(for: occurrence.id)
        XCTAssertEqual(mockKit.scheduledAlarms.count, count, "Retry must not duplicate the next rescue.")
    }

    func testStopFailureKeepsMissionAndReusesPreparedCheckOnRetry() async throws {
        let alarm = Alarm(time: Date().addingTimeInterval(3600), missionType: .math)
        try store.addAlarm(alarm)
        try await coordinator.enableAlarm(alarm)
        let occurrence = store.activeOccurrence(forAlarmId: alarm.id)!
        try store.updateOccurrenceStatus(id: occurrence.id, status: .missionPending)
        mockKit.alertingAlarmIDs.insert(occurrence.primaryAlarmKitId)
        mockKit.shouldFailOnStop = true
        do {
            try await coordinator.completeMission(for: occurrence.id)
            XCTFail("A stop failure must leave the mission available for retry.")
        } catch SchedulerError.cancellationFailed { }
        let pending = store.occurrence(for: occurrence.id)!
        XCTAssertEqual(pending.status, .missionPending)
        XCTAssertNotNil(mockKit.scheduledAlarms[occurrence.rescueAlarmKitId])
        XCTAssertNotNil(pending.wakeUpCheckRescueId)
        mockKit.shouldFailOnStop = false
        try await coordinator.completeMission(for: occurrence.id)
        XCTAssertEqual(store.occurrence(for: occurrence.id)?.wakeUpCheckRescueId, pending.wakeUpCheckRescueId)
        XCTAssertEqual(store.occurrence(for: occurrence.id)?.status, .wakeUpCheckPending)
        XCTAssertEqual(mockKit.scheduledAlarms.count, 1)
    }

    func testExpiredCheckCreatesFutureWindowAndCleansPreviousRescue() async throws {
        let alarm = Alarm(time: Date(), missionType: .math)
        try store.addAlarm(alarm)
        let oldRescue = UUID()
        let occurrence = OccurrenceState(alarmId: alarm.id, scheduledFireDate: Date().addingTimeInterval(-600),
            wakeUpCheckRescueId: oldRescue, wakeUpCheckAt: Date().addingTimeInterval(-200),
            wakeUpCheckDeadline: Date().addingTimeInterval(-100), missionType: .math, status: .ringing)
        try store.saveOccurrence(occurrence)
        mockKit.scheduledAlarms[oldRescue] = ("Old check", Date().addingTimeInterval(-100), true)
        try await coordinator.completeMission(for: occurrence.id)
        let updated = store.occurrence(for: occurrence.id)!
        XCTAssertNotEqual(updated.wakeUpCheckRescueId, oldRescue)
        XCTAssertGreaterThan(updated.wakeUpCheckDeadline!, Date())
        XCTAssertNil(mockKit.scheduledAlarms[oldRescue])
    }

    func testInterruptedReplacementRestoresOriginalAndRemovesStagedPair() async throws {
        let alarm = Alarm(time: Date().addingTimeInterval(3600), label: "Original", missionType: .math)
        try store.addAlarm(alarm)
        try await coordinator.enableAlarm(alarm)
        let previous = store.activeOccurrence(forAlarmId: alarm.id)!
        let originalIDs = Set(mockKit.scheduledAlarms.keys)
        var interrupted = OccurrenceState(alarmId: alarm.id,
            scheduledFireDate: Date().addingTimeInterval(7200), missionType: .math, status: .preparing)
        interrupted.replacementAlarmIDs = Array(originalIDs)
        interrupted.replacementWasEnabled = true
        try store.saveOccurrence(interrupted)
        mockKit.scheduledAlarms.removeValue(forKey: previous.primaryAlarmKitId)
        mockKit.scheduledAlarms[interrupted.primaryAlarmKitId] = ("Interrupted", interrupted.scheduledFireDate, false)
        mockKit.scheduledAlarms[interrupted.rescueAlarmKitId] = ("Interrupted rescue", interrupted.scheduledFireDate.addingTimeInterval(180), true)

        let recovered = expectation(description: "Interrupted replacement recovered")
        let observer = store.$occurrences.receive(on: DispatchQueue.main).sink { occurrences in
            if !occurrences.contains(where: { $0.id == interrupted.id }) {
                // Reading through the serial store must be safe after delivery.
                XCTAssertEqual(self.store.alarm(for: alarm.id)?.label, "Original")
                recovered.fulfill()
            }
        }
        coordinator.reconcileInForeground()
        await fulfillment(of: [recovered], timeout: 2)
        observer.cancel()
        XCTAssertEqual(Set(mockKit.scheduledAlarms.keys), originalIDs)
        XCTAssertEqual(store.alarm(for: alarm.id)?.isEnabled, true)
    }
}
