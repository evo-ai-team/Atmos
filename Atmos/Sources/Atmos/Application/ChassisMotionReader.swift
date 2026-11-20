import Foundation
import IOKit
import IOKit.hid

/// Streams the built-in MacBook accelerometer on models exposing Apple's SPU
/// HID report. All callbacks run on the main run loop, including in menu tracking.
@MainActor
final class ChassisMotionReader {
    enum Failure: LocalizedError {
        case unavailable, open(IOReturn), stalled

        var errorDescription: String? {
            switch self {
            case .unavailable:
                return "This Mac does not expose a compatible built-in motion sensor."
            case .open(let status):
                return String(format: "macOS could not open the built-in motion sensor (0x%08x).", status)
            case .stalled:
                return "The built-in motion sensor stopped sending samples."
            }
        }
    }

    private static let reportBytes = 22
    private static let intervalKey = "ReportInterval" as CFString
    private static let intervalMicroseconds = 10_000
    private static let secondsPerTick: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom) / 1_000_000_000
    }()

    private let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: ChassisMotionReader.reportBytes)
    private var device: IOHIDDevice?
    private var driver: io_service_t = 0
    private var previousInterval: Int?
    private var watchdog: Timer?
    private var lastSampleAt: TimeInterval = 0
    private var onSample: ((TimeInterval, SIMD3<Double>) -> Void)?
    private var onFailure: ((String) -> Void)?

    isolated deinit {
        stop()
        buffer.deallocate()
    }

    func start(onSample: @escaping (TimeInterval, SIMD3<Double>) -> Void,
               onFailure: @escaping (String) -> Void) throws {
        stop()

        let match = IOServiceMatching("AppleSPUHIDDevice") as NSMutableDictionary
        match[kIOPropertyMatchKey] = ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 3,
                                      "Transport": "SPU", "MaxInputReportSize": Self.reportBytes] as [String: Any]
        let service = IOServiceGetMatchingService(kIOMainPortDefault, match)
        guard service != 0 else { throw Failure.unavailable }
        defer { IOObjectRelease(service) }
        guard let input = IOHIDDeviceCreate(kCFAllocatorDefault, service) else { throw Failure.unavailable }
        let status = IOHIDDeviceOpen(input, 0)
        guard status == kIOReturnSuccess else { throw Failure.open(status) }

        self.device = input
        self.onSample = onSample
        self.onFailure = onFailure
        lastSampleAt = ProcessInfo.processInfo.systemUptime
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportWithTimeStampCallback(input, buffer, Self.reportBytes,
            { context, result, _, _, _, bytes, length, ticks in
                guard let context, result == kIOReturnSuccess, length == 22 else { return }
                let raw = UnsafeRawBufferPointer(start: bytes, count: length)
                // The accelerometer payload is three little-endian signed Q16 values.
                func axis(_ offset: Int) -> Double {
                    Double(Int32(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: Int32.self))) / 65_536
                }
                let acceleration = SIMD3(axis(6), axis(10), axis(14))
                let reader = Unmanaged<ChassisMotionReader>.fromOpaque(context).takeUnretainedValue()
                MainActor.assumeIsolated {
                    let capturedAt = Double(ticks) * ChassisMotionReader.secondsPerTick
                    // Only live reports from this capture may drive a gesture.
                    // A busy UI run loop can deliver older reports in a burst.
                    guard capturedAt > reader.lastSampleAt,
                          ProcessInfo.processInfo.systemUptime - capturedAt < 0.25 else { return }
                    reader.lastSampleAt = capturedAt
                    reader.onSample?(capturedAt, acceleration)
                }
            }, context)
        IOHIDDeviceScheduleWithRunLoop(input, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)

        // A cold accelerometer enumerates and opens successfully, but typically
        // remains silent until the accelerometer driver receives a report interval.
        driver = Self.accelerometerDriver(below: service)
        if driver != 0 {
            let prior = Self.interval(of: driver)
            if prior <= 0 || prior > Self.intervalMicroseconds {
                if IORegistryEntrySetCFProperty(driver, Self.intervalKey, Self.intervalMicroseconds as CFNumber) == kIOReturnSuccess {
                    previousInterval = prior
                }
            }
        }

        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, ProcessInfo.processInfo.systemUptime - self.lastSampleAt >= 2 else { return }
                let notify = self.onFailure
                self.stop()
                notify?(Failure.stalled.localizedDescription)
            }
        }
        watchdog = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stop() {
        watchdog?.invalidate()
        watchdog = nil
        onSample = nil
        onFailure = nil
        if let device {
            IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            IOHIDDeviceClose(device, 0)
            self.device = nil
        }
        if driver != 0 {
            // Preserve an interval that was active before us or changed by another client.
            if let previousInterval, Self.interval(of: driver) == Self.intervalMicroseconds {
                IORegistryEntrySetCFProperty(driver, Self.intervalKey, previousInterval as CFNumber)
            }
            IOObjectRelease(driver)
            driver = 0
        }
        previousInterval = nil
    }

    private static func interval(of service: io_service_t) -> Int {
        let value = IORegistryEntryCreateCFProperty(service, intervalKey, kCFAllocatorDefault, 0)?.takeRetainedValue()
        return (value as? NSNumber)?.intValue ?? 0
    }

    private static func accelerometerDriver(below service: io_service_t) -> io_service_t {
        var iterator: io_iterator_t = 0
        guard IORegistryEntryCreateIterator(service, kIOServicePlane,
            IOOptionBits(kIORegistryIterateRecursively), &iterator) == kIOReturnSuccess else { return 0 }
        defer { IOObjectRelease(iterator) }
        var child = IOIteratorNext(iterator)
        while child != 0 {
            if IOObjectConformsTo(child, "AppleSPUHIDDriver") != 0 { return child }
            IOObjectRelease(child)
            child = IOIteratorNext(iterator)
        }
        return 0
    }
}
