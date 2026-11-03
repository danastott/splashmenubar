import Foundation

/// Reads the Apple silicon die temperature from the IOKit HID event system
/// (the "PMU tdie" sensors), which needs no privileges. These calls are
/// private API, so they are looked up at runtime: if a macOS release drops
/// them, `celsius()` returns nil and the app simply shows no temperature.
final class ThermalSensor {
    private typealias CreateFn = @convention(c) (CFAllocator?) -> Unmanaged<CFTypeRef>?
    private typealias SetMatchingFn = @convention(c) (CFTypeRef, CFDictionary) -> Int32
    private typealias CopyServicesFn = @convention(c) (CFTypeRef) -> Unmanaged<CFArray>?
    private typealias CopyPropertyFn = @convention(c) (CFTypeRef, CFString) -> Unmanaged<CFTypeRef>?
    private typealias CopyEventFn = @convention(c) (CFTypeRef, Int64, Int32, Int64) -> Unmanaged<CFTypeRef>?
    private typealias GetFloatFn = @convention(c) (CFTypeRef, Int32) -> Double

    private static let temperatureEventType: Int64 = 15            // kIOHIDEventTypeTemperature
    private static let temperatureField: Int32 = 15 << 16          // kIOHIDEventFieldTemperatureLevel

    private let copyEvent: CopyEventFn
    private let getFloat: GetFloatFn
    private let client: CFTypeRef
    /// The die sensors, found once.
    private let dieSensors: [CFTypeRef]

    init?() {
        guard let iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY),
              let create = Self.symbol(iokit, "IOHIDEventSystemClientCreate", as: CreateFn.self),
              let setMatching = Self.symbol(iokit, "IOHIDEventSystemClientSetMatching", as: SetMatchingFn.self),
              let copyServices = Self.symbol(iokit, "IOHIDEventSystemClientCopyServices", as: CopyServicesFn.self),
              let copyProperty = Self.symbol(iokit, "IOHIDServiceClientCopyProperty", as: CopyPropertyFn.self),
              let copyEvent = Self.symbol(iokit, "IOHIDServiceClientCopyEvent", as: CopyEventFn.self),
              let getFloat = Self.symbol(iokit, "IOHIDEventGetFloatValue", as: GetFloatFn.self),
              let client = create(kCFAllocatorDefault)?.takeRetainedValue()
        else { return nil }

        // Apple vendor usage page, temperature sensor usage.
        let matching = ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary
        _ = setMatching(client, matching)
        guard let services = copyServices(client)?.takeRetainedValue() as [AnyObject]? else { return nil }

        let dies = services.filter { service in
            let name = copyProperty(service, "Product" as CFString)?.takeRetainedValue() as? String
            return name?.hasPrefix("PMU tdie") == true
        }
        guard !dies.isEmpty else { return nil }

        self.client = client
        self.copyEvent = copyEvent
        self.getFloat = getFloat
        self.dieSensors = dies
    }

    /// The hottest die sensor, in °C (nil if none gives a plausible reading).
    func celsius() -> Double? {
        let readings = dieSensors.compactMap { sensor -> Double? in
            guard let event = copyEvent(sensor, Self.temperatureEventType, 0, 0)?.takeRetainedValue() else {
                return nil
            }
            let v = getFloat(event, Self.temperatureField)
            return (1...150).contains(v) ? v : nil
        }
        return readings.max()
    }

    private static func symbol<T>(_ handle: UnsafeMutableRawPointer, _ name: String, as: T.Type) -> T? {
        guard let p = dlsym(handle, name) else { return nil }
        return unsafeBitCast(p, to: T.self)
    }
}

/// Formats temperatures in the unit the user picked in System Settings ›
/// General › Language & Region, else their region's default.
enum TemperatureUnit {
    static var usesFahrenheit: Bool {
        // Set when the user chooses a unit explicitly.
        if let pref = UserDefaults.standard.string(forKey: "AppleTemperatureUnit") {
            return pref == "Fahrenheit"
        }
        // A locale override such as en_GB@mu=fahrenhe.
        let id = Locale.current.identifier.lowercased()
        if id.contains("mu=fahrenhe") { return true }
        if id.contains("mu=celsius") { return false }
        return Locale.current.measurementSystem == .us
    }

    /// e.g. "115°F" or "46°C".
    static func format(celsius c: Double) -> String {
        usesFahrenheit
            ? String(format: "%.0f°F", c * 9 / 5 + 32)
            : String(format: "%.0f°C", c)
    }
}
