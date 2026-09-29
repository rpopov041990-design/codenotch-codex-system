import SwiftUI
import Darwin
import IOKit.ps

enum MetricHealth: Equatable {
    case normal, warning, serious, critical, unknown
    var color: Color {
        switch self {
        case .normal: return .green
        case .warning: return .yellow
        case .serious: return .orange
        case .critical: return .red
        case .unknown: return .gray
        }
    }
    var label: String {
        switch self {
        case .normal: return "Норма"
        case .warning: return "Повышенное"
        case .serious: return "Высокое"
        case .critical: return "Критическое"
        case .unknown: return "Нет данных"
        }
    }
    static func thermal(_ state: ProcessInfo.ThermalState) -> Self {
        switch state {
        case .nominal: return .normal
        case .fair: return .warning
        case .serious: return .serious
        case .critical: return .critical
        @unknown default: return .unknown
        }
    }
    // sysctl exports dispatch flags, not the kernel's internal 0...3 enum.
    static func memoryPressure(_ flag: Int32?) -> Self {
        switch flag {
        case 1: return .normal
        case 2: return .warning
        case 4: return .critical
        default: return .unknown
        }
    }
    static func readMemoryPressure() -> Self {
        var flag: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &flag, &size, nil, 0) == 0,
              size == MemoryLayout<Int32>.size else { return .unknown }
        return memoryPressure(flag)
    }
}

struct SystemMetric: Identifiable, Equatable {
    let id: String
    let title: String
    let symbol: String
    let fraction: Double?
    let value: String
    let detail: String
    var health: MetricHealth? = nil
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
    private let chipTemperature = ChipTemperature()

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
        let thermalHealth = MetricHealth.thermal(ProcessInfo.processInfo.thermalState)
        let memoryHealth = MetricHealth.readMemoryPressure()
        func percent(_ value: Double?) -> String {
            value.map { "\(Int(($0 * 100).rounded()))%" } ?? "—"
        }
        func bytes(_ value: Double) -> String {
            ByteCountFormatter.string(fromByteCount: Int64(max(0, value)), countStyle: .file)
        }
        let temperatures = chipTemperature.read()
        let average = ChipTemperature.mean(temperatures.cpu + temperatures.gpu)
        let temperatureDetail = average.map { _ in
            "Зоны CPU/GPU: \(temperatures.cpu.count)/\(temperatures.gpu.count). Среднее, °C."
        } ?? "Датчики CPU/GPU недоступны."
        return [
            SystemMetric(id: "system.ram", title: "Оперативная память", symbol: "memorychip", fraction: ram,
                         value: percent(ram), detail: "Давление: \(memoryHealth.label). Цвет — давление macOS, не % занятости.\n" + (ram == nil ? "Объём: нет данных." : "Занято \(bytes(usedRAM)) из \(bytes(totalRAM))."), health: memoryHealth),
            SystemMetric(id: "system.cpu", title: "Процессор", symbol: "cpu", fraction: cpuFraction,
                         value: percent(cpuFraction), detail: "Общая загрузка процессора за интервал измерения. Первое значение появится через 3 секунды."),
            SystemMetric(id: "system.disk", title: "Диск", symbol: "internaldrive", fraction: diskFraction,
                         value: percent(diskFraction), detail: diskFraction == nil ? "Нет данных" : "Занято \(bytes(usedDisk)) из \(bytes(totalDisk)). Свободно \(bytes(freeDisk)). Том домашней папки; очищаемое место может учитываться macOS иначе."),
            SystemMetric(id: "system.thermal", title: "Средняя температура CPU/GPU", symbol: "thermometer.medium", fraction: nil,
                         value: average.map { String(format: "%.0f°", $0) } ?? "—",
                         detail: "Нагрев macOS: \(thermalHealth.label). Цвет — состояние ОС.\n" + temperatureDetail + "\nПредел кристалла M5 не подтверждён.", health: thermalHealth)
        ] + BatteryReading.read().map { [$0.metric] }.orEmpty
    }
}

struct SystemMetricCell: View {
    let metric: SystemMetric
    var animate = false
    @Environment(\.codenotchAccentColor) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false
    var body: some View {
        VStack(spacing: NotchLayout.ringLabelGap) {
            ZStack {
                Circle().strokeBorder(metric.id == "system.thermal" ? (metric.health?.color ?? .gray) : Palette.ringTrack, lineWidth: NotchLayout.trackStroke)
                if let fraction = metric.fraction {
                    Circle().inset(by: NotchLayout.trackStroke / 2).trim(from: 0, to: appeared ? fraction : 0)
                        .stroke(metric.health?.color ?? UsageBand.band(for: metric.isBattery ? 1 - fraction : fraction).color(accent: accent),
                                style: StrokeStyle(lineWidth: NotchLayout.progressStroke, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                if metric.id == "system.thermal" {
                    Text(metric.value).font(.system(size: NotchLayout.ringDiameter * 0.30, weight: .semibold))
                        .monospacedDigit().contentTransition(.numericText())
                        .foregroundStyle(Color.black)
                } else if metric.id == "system.tokens" {
                    TimelineView(.animation(minimumInterval: 0.15, paused: !animate || reduceMotion)) { context in
                        HStack(alignment: .bottom, spacing: 3) {
                            ForEach(0..<3) { index in
                                let phase = context.date.timeIntervalSinceReferenceDate * 2 + Double(index) * 1.4
                                let level = (!animate || reduceMotion) ? Double(index + 2) / 5 : 0.3 + 0.7 * (sin(phase) + 1) / 2
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(Palette.textPrimary)
                                    .frame(width: NotchLayout.ringDiameter * 0.10, height: NotchLayout.ringDiameter * 0.40 * level)
                            }
                        }.frame(height: NotchLayout.ringDiameter * 0.40, alignment: .bottom)
                    }
                } else {
                Image(systemName: metric.symbol).font(.system(size: NotchLayout.ringDiameter * 0.4))
                    .foregroundStyle(Palette.textPrimary)
                    .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion && metric.id == "system.tokens")
                }
            }.frame(width: NotchLayout.ringDiameter, height: NotchLayout.ringDiameter)
            Text(metric.id == "system.thermal" ? "CPU/GPU" : metric.value).font(Typography.percent)
                .foregroundStyle(metric.id == "system.tokens" ? Color.black : Palette.textPrimary)
                .contentTransition(.numericText())
                .lineLimit(1).minimumScaleFactor(0.5)
                .frame(width: NotchLayout.ringDiameter, height: NotchLayout.percentLineHeight)
        }
        .frame(height: NotchLayout.cellExtent)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.65), value: metric)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.7), value: appeared)
        .onAppear { appeared = true }
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
    @AppStorage("system.tokens.enabled") private var tokens = true
    @AppStorage("quota.people") private var people = 3
    @AppStorage("quota.myWeight") private var myWeight = 2
    var body: some View {
        Section("Системные показатели") {
            Toggle("Оперативная память", isOn: $ram)
            Toggle("Процессор", isOn: $cpu)
            Toggle("Заполненность диска", isOn: $disk)
            Toggle("Средняя температура CPU/GPU", isOn: $thermal)
            Toggle("Заряд и состояние АКБ", isOn: $battery)
            Toggle("Личные токены Codex — отдельный график", isOn: $tokens)
            Picker("Пользователей общего лимита", selection: $people) {
                ForEach(1...4, id: \.self) { Text("\($0)").tag($0) }
            }.pickerStyle(.segmented)
            Picker("Вес моей доли", selection: $myWeight) {
                ForEach(1...4, id: \.self) { Text("\($0)×").tag($0) }
            }.pickerStyle(.segmented).disabled(people == 1)
            Text("Остальные имеют вес 1. Это план долей общего лимита, не измерение расхода каждого человека.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Показатели обновляются каждые 3 секунды при раскрытой панели. Температура — среднее доступных датчиков CPU/GPU, иначе — прочерк. Токены приходят из профиля Codex и могут запаздывать; это не процент лимита. Пульсация значка — оформление, не признак работы ИИ.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct DailyQuotaBudget {
    let percentPerDay: Double
    let remainingPercent: Double
    let reset: Date
    static func calculate(used: Double?, reset: Date?, now: Date) -> Self? {
        guard let used, used.isFinite, used >= 0,
              let reset, reset.timeIntervalSince(now).isFinite, reset > now else { return nil }
        let left = max(0, 1 - used) * 100
        let days = max(1, reset.timeIntervalSince(now) / 86_400)
        return Self(percentPerDay: left * 0.9 / days, remainingPercent: left, reset: reset)
    }
    // Round down to avoid recommending more than the computed budget.
    var dailyText: String {
        if percentPerDay > 0 && percentPerDay < 0.1 { return "<0,1" }
        return String(format: "%.1f", locale: Locale(identifier: "ru_RU"), floor(percentPerDay * 10) / 10)
    }
}

struct QuotaSharing {
    let people: Int
    let weight: Int
    init(people: Int, weight: Int) {
        self.people = min(4, max(1, people))
        self.weight = min(4, max(1, weight))
    }
    var mine: Double { Double(weight) / Double(weight + people - 1) }
    var eachOther: Double { people > 1 ? 1 / Double(weight + people - 1) : 0 }
    func dailyText(total: Double, share: Double) -> String {
        let value = max(0, total * share)
        if value > 0 && value < 0.1 { return "<0,1" }
        return String(format: "%.1f", locale: Locale(identifier: "ru_RU"), floor(value * 10) / 10)
    }
}

struct PersonalTokenCard: View {
    let usage: CodexTokenUsage?
    let quota: ProviderSnapshot?
    let now: Date
    // The reference mock-up is about 430 physical pixels tall on a Retina
    // display, i.e. roughly 215 points. Keep a little extra room for the
    // sharing controls without making the whole side panel taller than the
    // screen when several providers are visible.
    static let height: CGFloat = 260
    @AppStorage("quota.people") private var people = 3
    @AppStorage("quota.myWeight") private var myWeight = 2
    @Environment(\.codenotchAccentColor) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visible = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Личные токены Codex").font(.headline)
            let sharing = QuotaSharing(people: people, weight: myWeight)
            Text("Пользователей: \(sharing.people) · твой вес: \(sharing.weight)×")
                .font(.caption)
            HStack(spacing: 6) {
                Image(systemName: "arrow.counterclockwise.circle.fill")
                if let quota, quota.status == .ok, let count = quota.resetCreditsAvailable {
                    Text("Сбросов в запасе: \(count)")
                } else {
                    Text("Сбросов в запасе: нет данных")
                }
            }
            .font(.caption.bold())
            .padding(7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(accent.opacity(0.13), in: RoundedRectangle(cornerRadius: 8))
            Text("Резерв отдельно от бюджета; автоматически не применяется.")
                .font(.caption2).foregroundStyle(.secondary)
            if let quota, quota.status == .ok,
               let weekly = quota.windows.first(where: { $0.duration == 604_800 }),
               let budget = DailyQuotaBudget.calculate(used: weekly.usedFraction, reset: weekly.resetsAt, now: now) {
                Text("Тебе: до \(sharing.dailyText(total: budget.percentPerDay, share: sharing.mine))% в сутки")
                    .font(.subheadline.bold())
                if sharing.people > 1 {
                    Text("Каждому из остальных: \(sharing.dailyText(total: budget.percentPerDay, share: sharing.eachOther))%/сутки")
                        .font(.caption)
                }
                Text("Общий ориентир: \(budget.dailyText)%/сутки")
                    .font(.caption)
                Text("Недельного лимита · запас 10% остатка")
                    .font(.caption2).foregroundStyle(.secondary)
                Text("Сброс: \(budget.reset.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption2)
                if let short = quota.windows.first(where: { $0.duration == 18_000 }),
                   let used = short.usedFraction, used.isFinite, used >= 0,
                   let reset = short.resetsAt, reset > now {
                    Text("5 часов: осталось \(Int(floor(max(0, 1 - used) * 100)))%")
                        .font(.caption).foregroundStyle(used >= 1 ? Color.red : Color.secondary)
                }
                Text("План долей, не контроль других пользователей. Не гарантия доступа.")
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                Text("Дневной ориентир недоступен: нужны свежие данные недельного лимита и сброса.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let usage, !usage.dailyUsageBuckets.isEmpty {
                let buckets = usage.last30Days(now: now)
                let maximum = max(1, buckets.map(\.tokens).max() ?? 0)
                Text("Сегодня: \(usage.usageToday(now: now).map { UsageFormat.tokens($0) } ?? "ожидаются данные") · 30 дней: \(UsageFormat.tokens(usage.usageInLast30Days(now: now)))")
                    .font(.caption).lineLimit(1).minimumScaleFactor(0.7)
                HStack(alignment: .bottom, spacing: 3) {
                    ForEach(buckets) { bucket in
                        let reported = usage.dailyUsageBuckets.contains { $0.startDate == bucket.startDate }
                        RoundedRectangle(cornerRadius: 2)
                            .fill(reported ? accent : Color.secondary.opacity(0.2))
                            .frame(maxWidth: .infinity)
                            .frame(height: max(2, (visible ? 65 : 0) * Double(max(0, bucket.tokens)) / Double(maximum)))
                            .help("\(bucket.startDate): \(reported ? UsageFormat.tokens(bucket.tokens) : "нет данных")")
                            .accessibilityLabel("\(bucket.startDate): \(reported ? UsageFormat.tokens(bucket.tokens) : "нет данных")")
                    }
                }.frame(height: 65, alignment: .bottom)
                HStack { Text(buckets.first?.startDate ?? ""); Spacer(); Text("Сегодня") }.font(.caption2)
                Text("Весь аккаунт Codex · данные сервера с задержкой. Серый — нет данных; высота — токены за день.")
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                Text("Данные расхода пока недоступны. Это не нулевой расход.").font(.callout)
            }
        }.padding(18)
            .frame(width: NotchLayout.cardWidth, height: Self.height, alignment: .topLeading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
            .animation(reduceMotion ? nil : .easeOut(duration: 0.65), value: visible)
            .onAppear { visible = true }
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
