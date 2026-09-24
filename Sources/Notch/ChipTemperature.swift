import Foundation
import IOKit

/// Read-only AppleSMC telemetry. Undocumented interface: fail closed when unavailable.
/// M5 sensor families cross-checked against exelban/stats Modules/Sensors/values.swift.
final class ChipTemperature {
    private var connection: io_connect_t = 0
    private var sizes: [String: (Int, UInt32)] = [:]
    private let keys = ["Tp00", "Tp04", "Tp08", "Tp0C", "Tp0G", "Tp0K", "Tp0O",
                        "Tp0R", "Tp0U", "Tp0X", "Tp0a", "Tp0d", "Tp0g",
                        "Tp0j", "Tp0m", "Tp0p", "Tp0u", "Tp0y",
                        "Tg0U", "Tg0X", "Tg0d", "Tg0g", "Tg0j", "Tg1Y", "Tg1c", "Tg1g"]
    init() {
        // Only enable this explicit key map for M5. Other models need verified maps.
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var brand = [CChar](repeating: 0, count: max(1, size))
        sysctlbyname("machdep.cpu.brand_string", &brand, &size, nil, 0)
        guard String(cString: brand).contains("Apple M5") else { return }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }
        if IOServiceOpen(service, mach_task_self_, 0, &connection) != KERN_SUCCESS { connection = 0 }
    }
    deinit { if connection != 0 { IOServiceClose(connection) } }

    static func mean(_ values: [Double]) -> Double? {
        let valid = values.filter { $0.isFinite && $0 > 0 && $0 < 125 }
        return valid.isEmpty ? nil : valid.reduce(0, +) / Double(valid.count)
    }
    func read() -> (cpu: [Double], gpu: [Double]) {
        var cpu: [Double] = [], gpu: [Double] = []
        for key in keys {
            if let t = temperature(key), Self.mean([t]) != nil {
                if key.hasPrefix("Tp") { cpu.append(t) } else { gpu.append(t) }
            }
        }
        return (cpu, gpu)
    }
    private func request(_ key: String, command: UInt8, size: Int = 0) -> [UInt8]? {
        guard connection != 0 else { return nil }
        // SMCKeyData ABI: key 0, keyInfo 28, result 40, data8 42, bytes 48; size 80.
        var input = [UInt8](repeating: 0, count: 80)
        let code = key.utf8.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        for n in 0..<4 { input[n] = UInt8(truncatingIfNeeded: code >> (8 * n)) }
        input[28] = UInt8(size); input[42] = command
        var output = [UInt8](repeating: 0, count: 80)
        var outputSize = 80
        let status = input.withUnsafeBytes { src in
            output.withUnsafeMutableBytes { dst in
                IOConnectCallStructMethod(connection, 2, src.baseAddress, 80, dst.baseAddress, &outputSize)
            }
        }
        guard status == KERN_SUCCESS, outputSize == 80, output[40] == 0 else { return nil }
        return output
    }
    private func temperature(_ key: String) -> Double? {
        if sizes[key] == nil {
            guard let info = request(key, command: 9) else { return nil }
            let size = Int(info[28]) | Int(info[29]) << 8
            let type = (0..<4).reduce(UInt32(0)) { $0 | UInt32(info[32 + $1]) << (8 * $1) }
            guard size == 2 || size == 4 else { return nil }
            sizes[key] = (size, type)
        }
        guard let (size, type) = sizes[key], let data = request(key, command: 5, size: size) else { return nil }
        if type == 0x666c7420, size == 4 { // flt : native little-endian IEEE 754
            let bits = (0..<4).reduce(UInt32(0)) { $0 | UInt32(data[48 + $1]) << (8 * $1) }
            return Double(Float(bitPattern: bits))
        }
        if type == 0x73703738, size == 2 { // sp78: signed big-endian fixed point
            return Double(Int16(bitPattern: UInt16(data[48]) << 8 | UInt16(data[49]))) / 256
        }
        return nil
    }
}

#if TEMPERATURE_PROBE
@main struct TemperatureProbe {
    static func main() {
        let reading = ChipTemperature().read()
        print("CPU sensors:", reading.cpu.count, "mean:", ChipTemperature.mean(reading.cpu) as Any)
        print("GPU sensors:", reading.gpu.count, "mean:", ChipTemperature.mean(reading.gpu) as Any)
    }
}
#endif
