import SwiftUI
import Darwin
import IOKit.ps

struct SystemMetric: Identifiable, Equatable {
    let id: String
    let title: String
    let symbol: String
    let fraction: Double?
    let value: String
    let detail: String
    var isBattery: Bool { id == "system.battery" }

    // Presentation-only placeholders: never registered with providers or archives.
    var snapshot: ProviderSnapshot {
        ProviderSnapshot(id: id, displayName: title, glyph: .openai,
                         fidelity: .derived, status: .ok, windows: [])
    }
    static func ratio(used: Double, total: Double) -> Double? {
        guard used.isFinite, total.isFinite, total > 0 else { return nil }
        return min(1, max(0, used / total))
    }
}

final class SystemMetricsSampler {
    private var previousCPU: (busy: UInt64, total: UInt64)?

    func sample() -> [SystemMetric] {
        var cpu = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        let cpuResult = withUnsafeMutablePointer(to: &cpu) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        var cpuFraction: Double?
        if cpuResult == KERN_SUCCESS {
            let t = cpu.cpu_ticks
            let busy = UInt64(t.0) + UInt64(t.1) + UInt64(t.3)
            let total = busy + UInt64(t.2)
            if let old = previousCPU, total > old.total, busy >= old.busy {
                cpuFraction = SystemMetric.ratio(used: Double(busy - old.busy), total: Double(total - old.total))
            }
            previousCPU = (busy, total)
        } else { previousCPU = nil }

        var vm = vm_statistics64()
        var vmCount = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let vmResult = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(vmCount)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &vmCount)
            }
        }
        let totalRAM = Double(ProcessInfo.processInfo.physicalMemory)
        // App memory + wired + physical compressor pages, not file caches.
        let pages = Double(vm.internal_page_count) - Double(vm.purgeable_count)
            + Double(vm.wire_count) + Double(vm.compressor_page_count)
        let usedRAM = max(0, pages) * Double(vm_kernel_page_size)
        let ram = vmResult == KERN_SUCCESS ? SystemMetric.ratio(used: usedRAM, total: totalRAM) : nil
        let disk = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(
            forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey])
        let totalDisk = Double(disk?.volumeTotalCapacity ?? 0)
        let freeDisk = Double(disk?.volumeAvailableCapacity ?? 0)
        let usedDisk = totalDisk - freeDisk
        let diskFraction = SystemMetric.ratio(used: usedDisk, total: totalDisk)
        let thermal: String
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: thermal = "Норма"
        case .fair: thermal = "Тепло"
        case .serious: thermal = "Жарко"
        case .critical: thermal = "Критично"
        @unknown default: thermal = "Нет данных"
        }
        func percent(_ value: Double?) -> String {
            value.map { "\(Int(($0 * 100).rounded()))%" } ?? "—"
        }
        func bytes(_ value: Double) -> String {
            ByteCountFormatter.string(fromByteCount: Int64(max(0, value)), countStyle: .file)
        }
        return [
            SystemMetric(id: "system.ram", title: "Оперативная память", symbol: "memorychip", fraction: ram,
                         value: percent(ram), detail: ram == nil ? "Нет данных" : "Занято \(bytes(usedRAM)) из \(bytes(totalRAM)). Без файлового кэша; включает сжатую память."),
            SystemMetric(id: "system.cpu", title: "Процессор", symbol: "cpu", fraction: cpuFraction,
                         value: percent(cpuFraction), detail: "Общая загрузка процессора за интервал измерения. Первое значение появится через 3 секунды."),
            SystemMetric(id: "system.disk", title: "Диск", symbol: "internaldrive", fraction: diskFraction,
                         value: percent(diskFraction), detail: diskFraction == nil ? "Нет данных" : "Занято \(bytes(usedDisk)) из \(bytes(totalDisk)). Свободно \(bytes(freeDisk)). Том домашней папки; очищаемое место может учитываться macOS иначе."),
            SystemMetric(id: "system.thermal", title: "Нагрев", symbol: "thermometer.medium", fraction: nil,
                         value: thermal, detail: "Тепловое состояние macOS: \(thermal). Это не температура в градусах.")
        ] + BatteryReading.read().map { [$0.metric] }.orEmpty
    }
}

struct SystemMetricCell: View {
    let metric: SystemMetric
    @Environment(\.codenotchAccentColor) private var accent
    var body: some View {
        VStack(spacing: NotchLayout.ringLabelGap) {
            ZStack {
                Circle().strokeBorder(Palette.ringTrack, lineWidth: NotchLayout.trackStroke)
                if let fraction = metric.fraction {
                    Circle().inset(by: NotchLayout.trackStroke / 2).trim(from: 0, to: fraction)
                        .stroke(UsageBand.band(for: metric.isBattery ? 1 - fraction : fraction).color(accent: accent),
                                style: StrokeStyle(lineWidth: NotchLayout.progressStroke, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                Image(systemName: metric.symbol).font(.system(size: NotchLayout.ringDiameter * 0.4))
                    .foregroundStyle(Palette.textPrimary)
            }.frame(width: NotchLayout.ringDiameter, height: NotchLayout.ringDiameter)
            Text(metric.value).font(Typography.percent).foregroundStyle(Palette.textPrimary)
                .lineLimit(1).minimumScaleFactor(0.5)
                .frame(width: NotchLayout.ringDiameter, height: NotchLayout.percentLineHeight)
        }
        .frame(height: NotchLayout.cellExtent)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(metric.title): \(metric.value). \(metric.detail)")
        .help("\(metric.title): \(metric.value)\n\(metric.detail)")
    }
}

struct SystemMetricsSettings: View {
    @AppStorage("system.ram.enabled") private var ram = true
    @AppStorage("system.cpu.enabled") private var cpu = true
    @AppStorage("system.disk.enabled") private var disk = true
    @AppStorage("system.thermal.enabled") private var thermal = true
    @AppStorage("system.battery.enabled") private var battery = true
    var body: some View {
        Section("Системные показатели") {
            Toggle("Оперативная память", isOn: $ram)
            Toggle("Процессор", isOn: $cpu)
            Toggle("Заполненность диска", isOn: $disk)
            Toggle("Состояние нагрева", isOn: $thermal)
            Toggle("Заряд и состояние АКБ", isOn: $battery)
            Text("Появляются вместе с панелью при наведении. Показатели читаются локально каждые 3 секунды, пока панель раскрыта. Нагрев — состояние macOS, не градусы.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private extension Optional where Wrapped == [SystemMetric] {
    var orEmpty: [SystemMetric] { self ?? [] }
}

struct BatteryReading {
    let fraction: Double?
    let charging: Bool
    let pluggedIn: Bool
    let health: String
    let cycles: Int?
    let maximumCapacity: Int?

    var metric: SystemMetric {
        let state = charging ? "Заряжается" : pluggedIn ? "Питание от сети, не заряжается" : "Питание от АКБ"
        let value = fraction.map { "\(Int(($0 * 100).rounded()))%" } ?? "—"
        var details = [state, "Состояние: \(health)"]
        details.append(maximumCapacity.map { "Макс. ёмкость: \($0)%" } ?? "Макс. ёмкость: нет данных")
        details.append(cycles.map { "Циклов: \($0)" } ?? "Циклы: нет данных")
        return SystemMetric(id: "system.battery", title: "Батарея", symbol: charging ? "battery.100percent.bolt" : "battery.100percent",
                            fraction: fraction, value: value, detail: details.joined(separator: "\n"))
    }

    static func read() -> BatteryReading? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in sources {
            guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            let fraction = SystemMetric.ratio(used: (d[kIOPSCurrentCapacityKey] as? NSNumber)?.doubleValue ?? .nan,
                                              total: (d[kIOPSMaxCapacityKey] as? NSNumber)?.doubleValue ?? 0)
            let rawHealth = d[kIOPSBatteryHealthKey] as? String
            let health: String
            switch rawHealth {
            case "Good": health = "Нормальное"
            case "Fair": health = "Износ"
            case "Poor": health = "Требуется обслуживание"
            default: health = "Нет данных"
            }
            // Read only the two optional numeric fields. Never collect serials or identifiers.
            let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
            var cycles: Int?
            var capacity: Int?
            if service != 0 {
                defer { IOObjectRelease(service) }
                cycles = (IORegistryEntryCreateCFProperty(service, "CycleCount" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber)?.intValue
                capacity = (IORegistryEntryCreateCFProperty(service, "MaximumCapacity" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber)?.intValue
            }
            return BatteryReading(fraction: fraction, charging: d[kIOPSIsChargingKey] as? Bool ?? false,
                                  pluggedIn: d[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue,
                                  health: health, cycles: cycles.flatMap { $0 >= 0 ? $0 : nil },
                                  maximumCapacity: capacity.flatMap { (1...100).contains($0) ? $0 : nil })
        }
        return nil // Desktop Macs without an internal battery get no invented indicator.
    }
}
