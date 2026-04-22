import XCTest
import BatteryCareShared

final class CommandCodableTests: XCTestCase {
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private func roundtrip(_ command: Command) throws -> Command {
        let data = try encoder.encode(command)
        return try decoder.decode(Command.self, from: data)
    }

    func testGetStatusRoundtrip() throws {
        guard case .getStatus = try roundtrip(.getStatus) else {
            XCTFail("Expected .getStatus"); return
        }
    }

    func testSetLimitRoundtrip() throws {
        guard case .setLimit(let p) = try roundtrip(.setLimit(percentage: 75)) else {
            XCTFail("Expected .setLimit"); return
        }
        XCTAssertEqual(p, 75)
    }

    func testSetPollingIntervalRoundtrip() throws {
        guard case .setPollingInterval(let s) = try roundtrip(.setPollingInterval(seconds: 5)) else {
            XCTFail("Expected .setPollingInterval"); return
        }
        XCTAssertEqual(s, 5)
    }

    func testSetSleepWakeIntervalRoundtrip() throws {
        guard case .setSleepWakeInterval(let m) = try roundtrip(.setSleepWakeInterval(minutes: 10)) else {
            XCTFail("Expected .setSleepWakeInterval"); return
        }
        XCTAssertEqual(m, 10)
    }

    func testEnableChargingRoundtrip() throws {
        guard case .enableCharging = try roundtrip(.enableCharging) else {
            XCTFail("Expected .enableCharging"); return
        }
    }

    func testDisableChargingRoundtrip() throws {
        guard case .disableCharging = try roundtrip(.disableCharging) else {
            XCTFail("Expected .disableCharging"); return
        }
    }

    func testStatusUpdateRoundtrip() throws {
        let update = StatusUpdate(
            currentPercentage: 72, isCharging: true, isPluggedIn: true,
            chargingState: .charging, mode: .normal,
            limit: 80, sailingLower: 80, pollingInterval: 3
        )
        let data = try encoder.encode(update)
        let decoded = try decoder.decode(StatusUpdate.self, from: data)
        XCTAssertEqual(decoded.currentPercentage, 72)
        XCTAssertEqual(decoded.chargingState, .charging)
        XCTAssertEqual(decoded.mode, .normal)
        XCTAssertNil(decoded.error)
    }

    func testStatusUpdateWithErrorRoundtrip() throws {
        let update = StatusUpdate(
            currentPercentage: 80, isCharging: false, isPluggedIn: true,
            chargingState: .limitReached, limit: 80, sailingLower: 80, pollingInterval: 3,
            error: .smcWriteFailed, errorDetail: "CH0B"
        )
        let data = try encoder.encode(update)
        let decoded = try decoder.decode(StatusUpdate.self, from: data)
        XCTAssertEqual(decoded.error, .smcWriteFailed)
        XCTAssertEqual(decoded.errorDetail, "CH0B")
    }

    func testUnknownCommandThrows() {
        let data = Data(#"{"type":"unknown"}"#.utf8)
        XCTAssertThrowsError(try decoder.decode(Command.self, from: data))
    }

    // MARK: - BatteryDetail

    func testBatteryDetailCodableRoundtrip() throws {
        let detail = BatteryDetail(
            rawPercentage: 85, cycleCount: 312, healthPercent: 91,
            maxCapacityMAh: 4821, designCapacityMAh: 5279,
            temperatureCelsius: 28.4, voltageMillivolts: 4100
        )
        let data = try encoder.encode(detail)
        let decoded = try decoder.decode(BatteryDetail.self, from: data)
        XCTAssertEqual(decoded, detail)
    }

    func testBatteryDetailJSONKeys() throws {
        let detail = BatteryDetail(
            rawPercentage: 85, cycleCount: 312, healthPercent: 91,
            maxCapacityMAh: 4821, designCapacityMAh: 5279,
            temperatureCelsius: 28.4, voltageMillivolts: 4100
        )
        let json = try JSONSerialization.jsonObject(with: encoder.encode(detail)) as! [String: Any]
        XCTAssertNotNil(json["rawPercentage"])
        XCTAssertNotNil(json["cycleCount"])
        XCTAssertNotNil(json["healthPercent"])
        XCTAssertNotNil(json["maxCapacityMAh"])
        XCTAssertNotNil(json["designCapacityMAh"])
        XCTAssertNotNil(json["temperatureCelsius"])
        XCTAssertNotNil(json["voltageMillivolts"])
    }

    // MARK: - StatusUpdate detail field

    func testStatusUpdateWithDetailRoundtrip() throws {
        let detail = BatteryDetail(
            rawPercentage: 85, cycleCount: 312, healthPercent: 91,
            maxCapacityMAh: 4821, designCapacityMAh: 5279,
            temperatureCelsius: 28.4, voltageMillivolts: 4100
        )
        let update = StatusUpdate(
            currentPercentage: 57, isCharging: true, isPluggedIn: true,
            chargingState: .charging, mode: .normal,
            limit: 80, sailingLower: 70, pollingInterval: 5,
            detail: detail
        )
        let data = try encoder.encode(update)
        let decoded = try decoder.decode(StatusUpdate.self, from: data)
        XCTAssertEqual(decoded.detail, detail)
    }

    func testStatusUpdateDetailDecodesNilWhenKeyMissing() throws {
        let json = Data("""
        {"currentPercentage":57,"isCharging":true,"isPluggedIn":true,"chargingState":"charging",
         "mode":"normal","limit":80,"sailingLower":70,"pollingInterval":5,"sleepWakeInterval":5}
        """.utf8)
        let decoded = try decoder.decode(StatusUpdate.self, from: json)
        XCTAssertNil(decoded.detail)
    }
}
