import XCTest
@testable import WakeFabio

final class ScheduleCalculationTests: XCTestCase {
    
    var calendar: Calendar!
    
    override func setUp() {
        super.setUp()
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        self.calendar = cal
    }
    
    func testOneTimeAlarmSameDayFuture() {
        // Data base: 2026-10-17 06:00:00 GMT
        var components = DateComponents()
        components.year = 2026
        components.month = 10
        components.day = 17
        components.hour = 6
        components.minute = 0
        let baseDate = calendar.date(from: components)!
        
        // Alarme para as 07:30 (ainda no mesmo dia)
        components.hour = 7
        components.minute = 30
        let alarmTime = calendar.date(from: components)!
        
        let alarm = Alarm(time: alarmTime, repeatDays: [])
        let nextFire = alarm.nextFireDate(after: baseDate, calendar: calendar)
        
        XCTAssertEqual(calendar.component(.year, from: nextFire), 2026)
        XCTAssertEqual(calendar.component(.month, from: nextFire), 10)
        XCTAssertEqual(calendar.component(.day, from: nextFire), 17)
        XCTAssertEqual(calendar.component(.hour, from: nextFire), 7)
        XCTAssertEqual(calendar.component(.minute, from: nextFire), 30)
    }
    
    func testOneTimeAlarmPassedTodaySpansToTomorrow() {
        // Data base: 2026-10-17 10:00:00 GMT
        var components = DateComponents()
        components.year = 2026
        components.month = 10
        components.day = 17
        components.hour = 10
        components.minute = 0
        let baseDate = calendar.date(from: components)!
        
        // Alarme configurado para 07:00 (já passou hoje)
        components.hour = 7
        components.minute = 0
        let alarmTime = calendar.date(from: components)!
        
        let alarm = Alarm(time: alarmTime, repeatDays: [])
        let nextFire = alarm.nextFireDate(after: baseDate, calendar: calendar)
        
        // Deve agendar para amanhã: 18 de Outubro às 07:00
        XCTAssertEqual(calendar.component(.day, from: nextFire), 18)
        XCTAssertEqual(calendar.component(.hour, from: nextFire), 7)
        XCTAssertEqual(calendar.component(.minute, from: nextFire), 0)
    }
    
    func testRepeatingAlarmWeekdays() {
        // 2026-10-17 é um Sábado (weekday = 7 no calendário gregoriano)
        var components = DateComponents()
        components.year = 2026
        components.month = 10
        components.day = 17
        components.hour = 8
        components.minute = 0
        let baseDate = calendar.date(from: components)!
        XCTAssertEqual(calendar.component(.weekday, from: baseDate), 7) // Sábado
        
        // Alarme configurado para repetir Seg a Sex (dias 2, 3, 4, 5, 6) às 07:00
        components.hour = 7
        components.minute = 0
        let alarmTime = calendar.date(from: components)!
        
        let alarm = Alarm(time: alarmTime, repeatDays: [2, 3, 4, 5, 6])
        let nextFire = alarm.nextFireDate(after: baseDate, calendar: calendar)
        
        // O próximo dia útil é Segunda-feira, 19 de Outubro (weekday = 2)
        XCTAssertEqual(calendar.component(.day, from: nextFire), 19)
        XCTAssertEqual(calendar.component(.weekday, from: nextFire), 2)
        XCTAssertEqual(calendar.component(.hour, from: nextFire), 7)
    }
    
    func testRepeatDaysSummaryDescriptions() {
        let single = Alarm(time: Date(), repeatDays: [])
        XCTAssertEqual(single.repeatDaysSummaryPt, "Apenas uma vez")
        
        let everyDay = Alarm(time: Date(), repeatDays: [1, 2, 3, 4, 5, 6, 7])
        XCTAssertEqual(everyDay.repeatDaysSummaryPt, "Todos os dias")
        
        let weekdays = Alarm(time: Date(), repeatDays: [2, 3, 4, 5, 6])
        XCTAssertEqual(weekdays.repeatDaysSummaryPt, "Dias úteis (Seg-Sex)")
        
        let weekend = Alarm(time: Date(), repeatDays: [1, 7])
        XCTAssertEqual(weekend.repeatDaysSummaryPt, "Fim de semana (Sáb-Dom)")
    }
}
