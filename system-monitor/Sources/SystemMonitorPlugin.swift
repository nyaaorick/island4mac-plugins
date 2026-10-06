import AppKit
import IslandKit

/// CPU, memory, network and disk as numbers, the busiest apps, and one of them beside the notch with a ring
@main
struct SystemMonitorPlugin: IslandPlugin {
    static let id = "system-monitor"
    static let name = "System"
    static let symbol = "gauge.with.dots.needle.33percent"
    static let version = "1.0.0"
    static let description: String? = "CPU, memory, network and disk, and the busiest apps"

    @Preference("Beside the notch", options: ["CPU", "Memory", "Network", "Off"]) var compact = "CPU"
    @Preference("Update every (seconds)", options: [1, 2, 5]) var interval = 2

    @State var reading: SystemReading? = nil

    var body: some IslandContent {
        if let reading {
            if let besideNotch = besideNotch(reading) {
                besideNotch
            }

            // Only while the tab shows: the rows change every few seconds, and nobody sees them otherwise
            if Island.isTabVisible {
                Row("CPU \(percent(reading.cpu))", subtitle: cpuDetail(reading), symbol: "cpu")
                Row("Memory \(bytes(reading.memoryUsed)) of \(bytes(reading.memoryTotal))", subtitle: memoryDetail(reading),
                    symbol: "memorychip")
                Row("Network ↓ \(rate(reading.received)) ↑ \(rate(reading.sent))",
                    subtitle: "\(bytes(reading.totalReceived)) received, \(bytes(reading.totalSent)) sent since startup",
                    symbol: "network")
                if let free = reading.diskFree, let total = reading.diskTotal, total > 0 {
                    Row("Disk \(bytes(free)) free", subtitle: "of \(bytes(total)), \(percent(1 - Double(free) / Double(total))) used",
                        symbol: "internaldrive")
                }
                for process in reading.top {
                    Row(process.name, subtitle: "\(String(format: "%.0f", process.cpu))% CPU · \(bytes(process.memory))",
                        symbol: "gearshape", image: process.bundleID.map { .app($0) }, id: "process-\(process.pid)",
                        actions: quitAction(process))
                }
            }
        }
    }

    // MARK: - Sampling

    func onStart() {
        let sampler = SystemSampler()
        var last = Date.distantPast
        // Ticks every second; samples at the chosen interval, and not at all while nothing shows the numbers
        let timer = Timer(timeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated {
                let visible = Island.isTabVisible
                guard visible || compact != "Off" else { return }
                let now = Date()
                guard now.timeIntervalSince(last) >= Double(interval) - 0.1 || (visible && reading?.top.isEmpty != false) else { return }
                last = now
                reading = sampler.sample(processes: visible)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        reading = sampler.sample(processes: false)
    }

    func quitAction(_ process: SystemReading.Process) -> [RowAction] {
        guard process.canQuit else { return [] }
        return [RowAction("Quit", symbol: "xmark.circle") {
            NSRunningApplication(processIdentifier: process.pid)?.terminate()
        }]
    }

    // MARK: - Text

    func besideNotch(_ reading: SystemReading) -> Compact? {
        switch compact {
        case "CPU": Compact(symbol: "cpu", text: percent(reading.cpu), progress: reading.cpu)
        case "Memory": Compact(symbol: "memorychip", text: percent(reading.memoryShare), progress: reading.memoryShare)
        case "Network": Compact(symbol: "arrow.down", text: shortRate(reading.received))
        default: nil
        }
    }

    func cpuDetail(_ reading: SystemReading) -> String {
        var parts = ["User \(percent(reading.cpuUser))", "System \(percent(reading.cpuSystem))",
                     "\(ProcessInfo.processInfo.activeProcessorCount) cores"]
        switch ProcessInfo.processInfo.thermalState {
        case .serious: parts.append("Running hot")
        case .critical: parts.append("Throttled, too hot")
        default: break
        }
        return parts.joined(separator: " · ")
    }

    func memoryDetail(_ reading: SystemReading) -> String {
        var parts = ["Pressure \(reading.pressure)", "Compressed \(bytes(reading.compressed))"]
        if reading.swap > 0 { parts.append("Swap \(bytes(reading.swap))") }
        return parts.joined(separator: " · ")
    }

    func percent(_ share: Double) -> String {
        "\(Int((share * 100).rounded()))%"
    }

    func bytes(_ count: UInt64) -> String {
        Int64(clamping: count).formatted(.byteCount(style: .memory))
    }

    func rate(_ perSecond: Double) -> String {
        "\(Int64(perSecond).formatted(.byteCount(style: .file)))/s"
    }

    /// "820K", "1.2M": short enough to sit beside the notch
    func shortRate(_ perSecond: Double) -> String {
        switch perSecond {
        case ..<1_000: return "\(Int(perSecond))B"
        case ..<1_000_000: return "\(Int(perSecond / 1_000))K"
        default: return String(format: "%.1fM", perSecond / 1_000_000)
        }
    }
}

/// One look at the system
struct SystemReading: Codable, Equatable {
    struct Process: Codable, Equatable {
        var pid: Int32
        var name: String
        var bundleID: String?
        /// An app in the Dock, which can be asked to quit (not a helper or a background process)
        var canQuit = false
        /// Percent of one core; above 100 for several
        var cpu: Double
        var memory: UInt64
    }

    /// Share of all cores in use, 0 to 1
    var cpu: Double
    var cpuUser: Double
    var cpuSystem: Double
    var memoryUsed: UInt64
    var memoryTotal: UInt64
    var compressed: UInt64
    var swap: UInt64
    /// "normal", "high" or "critical"
    var pressure: String
    /// Bytes a second
    var received: Double
    var sent: Double
    var totalReceived: UInt64
    var totalSent: UInt64
    var diskFree: UInt64?
    var diskTotal: UInt64?
    /// The busiest processes, read only while the tab shows
    var top: [Process]

    var memoryShare: Double {
        memoryTotal > 0 ? min(1, Double(memoryUsed) / Double(memoryTotal)) : 0
    }
}

/// Reads the counters and turns them into rates against the last reading
@MainActor
final class SystemSampler {
    private let host = mach_host_self()
    private var lastTicks: [UInt32]?
    private var lastNetwork: (received: UInt64, sent: UInt64, at: Date)?
    /// Each process's CPU time (nanoseconds) at the last process reading
    private var lastProcessTimes: [pid_t: UInt64] = [:]
    private var lastProcessRead: Date?
    private let timebase: (numer: UInt64, denom: UInt64) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (UInt64(info.numer), UInt64(max(info.denom, 1)))
    }()

    func sample(processes: Bool) -> SystemReading {
        let now = Date()
        let (cpu, user, system) = cpuShares()
        let memory = memoryNumbers()
        let network = networkBytes()
        var received = 0.0, sent = 0.0
        if let last = lastNetwork, now > last.at {
            let seconds = now.timeIntervalSince(last.at)
            received = Double(network.received &- last.received) / seconds
            sent = Double(network.sent &- last.sent) / seconds
            // Counters reset when an interface goes away
            if network.received < last.received { received = 0 }
            if network.sent < last.sent { sent = 0 }
        }
        lastNetwork = (network.received, network.sent, now)
        let disk = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeTotalCapacityKey,
                                                                            .volumeAvailableCapacityForImportantUsageKey])

        return SystemReading(
            cpu: cpu, cpuUser: user, cpuSystem: system,
            memoryUsed: memory.used, memoryTotal: ProcessInfo.processInfo.physicalMemory, compressed: memory.compressed,
            swap: swapUsed(), pressure: memoryPressure(),
            received: received, sent: sent, totalReceived: network.received, totalSent: network.sent,
            diskFree: disk?.volumeAvailableCapacityForImportantUsage.map { UInt64(max(0, $0)) },
            diskTotal: disk?.volumeTotalCapacity.map { UInt64(max(0, $0)) },
            top: processes ? busiestProcesses(now: now) : []
        )
    }

    // MARK: - CPU

    /// Share of all cores busy since the last reading: total, user (with nice) and system
    private func cpuShares() -> (Double, Double, Double) {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count) }
        }
        guard result == KERN_SUCCESS else { return (0, 0, 0) }
        let ticks = [info.cpu_ticks.0, info.cpu_ticks.1, info.cpu_ticks.2, info.cpu_ticks.3]
        defer { lastTicks = ticks }
        guard let last = lastTicks else { return (0, 0, 0) }
        let delta = zip(ticks, last).map { Double($0 &- $1) }
        let total = delta.reduce(0, +)
        guard total > 0 else { return (0, 0, 0) }
        let user = (delta[Int(CPU_STATE_USER)] + delta[Int(CPU_STATE_NICE)]) / total
        let system = delta[Int(CPU_STATE_SYSTEM)] / total
        return (user + system, user, system)
    }

    // MARK: - Memory

    /// Used the way Activity Monitor counts it: app memory, wired and compressed
    private func memoryNumbers() -> (used: UInt64, compressed: UInt64) {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(host, HOST_VM_INFO64, $0, &count) }
        }
        guard result == KERN_SUCCESS else { return (0, 0) }
        let page = UInt64(getpagesize())
        let app = UInt64(stats.internal_page_count) - min(UInt64(stats.internal_page_count), UInt64(stats.purgeable_count))
        let compressed = UInt64(stats.compressor_page_count) * page
        return ((app + UInt64(stats.wire_count)) * page + compressed, compressed)
    }

    private func memoryPressure() -> String {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return "normal" }
        switch level {
        case 4: return "critical"
        case 2: return "high"
        default: return "normal"
        }
    }

    private func swapUsed() -> UInt64 {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return 0 }
        return usage.xsu_used
    }

    // MARK: - Network

    /// Bytes in and out since startup over Wi-Fi and Ethernet (en*), 64-bit counters. Tunnels (a VPN) are left
    /// out, or their traffic would count twice
    private func networkBytes() -> (received: UInt64, sent: UInt64) {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &length, nil, 0) == 0, length > 0 else { return (0, 0) }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, UInt32(mib.count), &buffer, &length, nil, 0) == 0 else { return (0, 0) }

        var received: UInt64 = 0, sent: UInt64 = 0
        buffer.withUnsafeBytes { raw in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= length {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                guard header.ifm_msglen > 0 else { break }
                if Int32(header.ifm_type) == RTM_IFINFO2, offset + MemoryLayout<if_msghdr2>.size <= length {
                    let message = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
                    if if_indextoname(UInt32(message.ifm_index), &name) != nil,
                       String(decoding: name.prefix { $0 != 0 }.map(UInt8.init), as: UTF8.self).hasPrefix("en") {
                        received += message.ifm_data.ifi_ibytes
                        sent += message.ifm_data.ifi_obytes
                    }
                }
                offset += Int(header.ifm_msglen)
            }
        }
        return (received, sent)
    }

    // MARK: - Processes

    /// The 3 processes that used the most CPU since the last reading. Only the user's own: others' can't be read
    /// without privileges
    private func busiestProcesses(now: Date) -> [SystemReading.Process] {
        let wanted = proc_listallpids(nil, 0)
        guard wanted > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(wanted) + 64)
        let found = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard found > 0 else { return [] }

        var times: [pid_t: UInt64] = [:]
        var memory: [pid_t: UInt64] = [:]
        for pid in pids.prefix(Int(found)) where pid > 0 {
            var usage = rusage_info_v2()
            let result = withUnsafeMutablePointer(to: &usage) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
            }
            guard result == 0 else { continue }
            times[pid] = (usage.ri_user_time + usage.ri_system_time) * timebase.numer / timebase.denom
            memory[pid] = usage.ri_phys_footprint
        }

        defer {
            lastProcessTimes = times
            lastProcessRead = now
        }
        // A reading from long ago would show an average, not what's busy now
        guard let lastRead = lastProcessRead, now.timeIntervalSince(lastRead) < 15 else { return [] }
        let elapsed = now.timeIntervalSince(lastRead) * 1_000_000_000
        guard elapsed > 0 else { return [] }

        let busiest = times.compactMap { pid, time -> (pid_t, Double)? in
            guard let last = lastProcessTimes[pid], time >= last else { return nil }
            return (pid, Double(time - last) / elapsed * 100)
        }
        .sorted { $0.1 > $1.1 }
        .prefix(3)

        return busiest.map { pid, cpu in
            let app = NSRunningApplication(processIdentifier: pid)
            return SystemReading.Process(pid: pid, name: app?.localizedName ?? processName(pid), bundleID: app?.bundleIdentifier,
                                         canQuit: app?.activationPolicy == .regular, cpu: cpu, memory: memory[pid] ?? 0)
        }
    }

    private func processName(_ pid: pid_t) -> String {
        var name = [CChar](repeating: 0, count: 256)
        guard proc_name(pid, &name, UInt32(name.count)) > 0 else { return "Process \(pid)" }
        return String(decoding: name.prefix { $0 != 0 }.map(UInt8.init), as: UTF8.self)
    }
}
