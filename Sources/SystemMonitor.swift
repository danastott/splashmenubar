import Foundation
import IOKit

/// One reading of whole-machine load, each as a 0...1 fraction.
struct SystemUsage: Equatable {
    var cpu: Double?
    var gpu: Double?
    var memory: Double?
    var memoryUsedBytes: UInt64?
    var memoryTotalBytes: UInt64?
}

/// Samples CPU, GPU and memory use with public Mach and IOKit calls (no
/// privileges). CPU use is the change in tick counters since the previous
/// `sample()`, so the first call returns no CPU figure.
final class SystemMonitor {
    private var lastTicks: (busy: UInt64, total: UInt64)?
    private let physicalMemory = ProcessInfo.processInfo.physicalMemory

    func sample() -> SystemUsage {
        var u = SystemUsage()
        u.cpu = cpuFraction()
        u.gpu = Self.gpuFraction()
        if let used = Self.memoryUsedBytes(), physicalMemory > 0 {
            u.memoryUsedBytes = used
            u.memoryTotalBytes = physicalMemory
            u.memory = min(Double(used) / Double(physicalMemory), 1)
        }
        return u
    }

    // MARK: - CPU

    /// Share of all cores' time spent busy (user + system + nice) since the
    /// previous sample.
    private func cpuFraction() -> Double? {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }

        let user = UInt64(info.cpu_ticks.0)
        let system = UInt64(info.cpu_ticks.1)
        let idle = UInt64(info.cpu_ticks.2)
        let nice = UInt64(info.cpu_ticks.3)
        let busy = user + system + nice
        let total = busy + idle
        defer { lastTicks = (busy, total) }

        guard let last = lastTicks, total > last.total, busy >= last.busy else { return nil }
        return min(Double(busy - last.busy) / Double(total - last.total), 1)
    }

    // MARK: - GPU

    /// "Device Utilization %" from the GPU driver's PerformanceStatistics
    /// (the figure Activity Monitor's GPU history uses). Busiest GPU wins.
    private static func gpuFraction() -> Double? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("IOAccelerator"),
                                           &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        var best: Double?
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            guard let stats = IORegistryEntryCreateCFProperty(
                    entry, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? [String: Any],
                  let pct = (stats["Device Utilization %"] as? NSNumber)?.doubleValue
            else { continue }
            best = max(best ?? 0, min(max(pct / 100, 0), 1))
        }
        return best
    }

    // MARK: - Memory

    /// "Memory Used" as Activity Monitor counts it: app memory (anonymous
    /// pages that aren't purgeable) + wired + compressed.
    private static func memoryUsedBytes() -> UInt64? {
        var vm = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }

        var pageSize: vm_size_t = 0
        guard host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS else { return nil }

        let anonymous = UInt64(vm.internal_page_count)
        let purgeable = UInt64(vm.purgeable_count)
        let app = anonymous > purgeable ? anonymous - purgeable : 0
        let pages = app + UInt64(vm.wire_count) + UInt64(vm.compressor_page_count)
        return pages * UInt64(pageSize)
    }
}
