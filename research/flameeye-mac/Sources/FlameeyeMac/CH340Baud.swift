import Foundation
import IOKit
import IOKit.usb

enum CH340Baud {
    // Call with the selected TTY open, after applying termios settings.
    static func configure921600(port: String) throws {
        guard port.hasPrefix("/dev/cu."), let service = try appleCH340Service(port: port) else { return }
        defer { IOObjectRelease(service) }

        // The UUID macros in IOCFPlugIn.h and IOUSBLib.h cannot be imported into Swift.
        let userClientID = CFUUIDCreateFromString(nil, "9DC7B780-9EC0-11D4-A54F-000A27052861" as CFString)!
        let pluginID = CFUUIDCreateFromString(nil, "C244E858-109C-11D4-91D4-0050E4C6426F" as CFString)!
        let interfaceID = CFUUIDCreateFromString(nil, "01A2D0E9-42F6-4A87-8B8B-77057C8CE0CE" as CFString)!

        var plugin: UnsafeMutablePointer<UnsafeMutablePointer<IOCFPlugInInterface>?>?
        var score: Int32 = 0
        let pluginStatus = IOCreatePlugInInterfaceForService(service, userClientID, pluginID, &plugin, &score)
        guard pluginStatus == KERN_SUCCESS, let plugin, let functions = plugin.pointee else {
            throw BaudError.io("打开 USB 控制接口", pluginStatus)
        }
        defer { IODestroyPlugInInterface(plugin) }

        var interface: UnsafeMutableRawPointer?
        let interfaceStatus = functions.pointee.QueryInterface(plugin, CFUUIDGetUUIDBytes(interfaceID), &interface)
        guard interfaceStatus == 0, let interface else {
            throw BaudError.io("取得 USB 控制接口", interfaceStatus)
        }
        let device = interface.assumingMemoryBound(to: UnsafeMutablePointer<IOUSBDeviceInterface320>.self)
        defer { _ = device.pointee.pointee.Release(device) }

        let version = try readWord(device, request: 0x5F, value: 0, operation: "读取桥接芯片版本")
        // CH340 uses 48 MHz / (4 × 13) ≈ 923077 baud, within 0.2% of 921600.
        // Linux ch341 enables immediate read on chips newer than version 0x27.
        let divisor: UInt16 = (version & 0xFF) > 0x27 ? 0xF387 : 0xF307
        let baudRegisters: UInt16 = 0x1312
        let current = try readWord(device, request: 0x95, value: baudRegisters, operation: "读取串口分频寄存器")
        let divisorMask: UInt16 = 0xFF7F
        guard current & divisorMask != divisor & divisorMask else { return }

        // Change only the volatile UART register pair. Keep AppleUSBCHCOM attached for serial I/O.
        var request = IOUSBDevRequestTO(bmRequestType: 0x40, bRequest: 0x9A, wValue: baudRegisters,
                                       wIndex: divisor, wLength: 0, pData: nil, wLenDone: 0,
                                       noDataTimeout: 1000, completionTimeout: 1000)
        try perform(device, request: &request, operation: "设置 921600 波特率")
        let actual = try readWord(device, request: 0x95, value: baudRegisters, operation: "复核串口分频寄存器")
        // Bit 7 controls buffering and does not appear in this bridge's register readback.
        guard actual & divisorMask == divisor & divisorMask else { throw BaudError.verification(actual) }
    }

    private typealias USBDevice = UnsafeMutablePointer<UnsafeMutablePointer<IOUSBDeviceInterface320>>

    private static func readWord(_ device: USBDevice, request command: UInt8, value: UInt16,
                                 operation: String) throws -> UInt16 {
        var bytes = [UInt8](repeating: 0, count: 2)
        try bytes.withUnsafeMutableBytes { buffer in
            var request = IOUSBDevRequestTO(bmRequestType: 0xC0, bRequest: command, wValue: value,
                                           wIndex: 0, wLength: 2, pData: buffer.baseAddress, wLenDone: 0,
                                           noDataTimeout: 1000, completionTimeout: 1000)
            try perform(device, request: &request, operation: operation)
            guard request.wLenDone == 2 else { throw BaudError.shortResponse(operation) }
        }
        return UInt16(bytes[0]) | (UInt16(bytes[1]) << 8)
    }

    private static func perform(_ device: USBDevice, request: inout IOUSBDevRequestTO, operation: String) throws {
        // Endpoint-zero requests do not claim the USB interface or re-enumerate the device.
        let status = device.pointee.pointee.DeviceRequestTO(device, &request)
        guard status == KERN_SUCCESS else { throw BaudError.io(operation, status) }
    }

    private static func appleCH340Service(port: String) throws -> io_service_t? {
        var iterator: io_iterator_t = 0
        let status = IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOSerialBSDClient"), &iterator)
        guard status == KERN_SUCCESS else { throw BaudError.io("查找所选串口", status) }
        defer { IOObjectRelease(iterator) }

        while case let serial = IOIteratorNext(iterator), serial != 0 {
            defer { IOObjectRelease(serial) }
            guard property(serial, "IOCalloutDevice") as? String == port else { continue }

            var entry = serial
            IOObjectRetain(entry)
            defer { IOObjectRelease(entry) }
            var appleDriver = false
            var parent: io_registry_entry_t = 0
            while IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent) == KERN_SUCCESS {
                IOObjectRelease(entry)
                entry = parent
                if IOObjectConformsTo(entry, "IOUSBHostDevice") != 0 || IOObjectConformsTo(entry, "IOUSBDevice") != 0 {
                    guard appleDriver, property(entry, "idVendor") as? Int == 0x1A86,
                          property(entry, "idProduct") as? Int == 0x7523 else { return nil }
                    IOObjectRetain(entry)
                    return entry
                }
                appleDriver = appleDriver || isAppleCHCOM(entry)
            }
            return nil
        }
        return nil
    }

    private static func isAppleCHCOM(_ entry: io_registry_entry_t) -> Bool {
        property(entry, "IOUserClass") as? String == "AppleUSBCHCOM"
            || property(entry, "CFBundleIdentifier") as? String == "com.apple.DriverKit-AppleUSBCHCOM"
            || property(entry, "IOUserServerName") as? String == "com.apple.DriverKit.AppleUSBCHCOM"
            || IOObjectConformsTo(entry, "AppleUSBCHCOM") != 0
    }

    private static func property(_ entry: io_registry_entry_t, _ name: String) -> CFTypeRef? {
        IORegistryEntryCreateCFProperty(entry, name as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    private enum BaudError: LocalizedError {
        case io(String, Int32)
        case shortResponse(String)
        case verification(UInt16)

        var errorDescription: String? {
            switch self {
            case let .io(operation, status):
                return "CH340 \(operation)失败（\(String(format: "0x%08X", UInt32(bitPattern: status)))）。"
            case let .shortResponse(operation):
                return "CH340 \(operation)时返回的数据长度不正确。"
            case let .verification(actual):
                return "CH340 分频寄存器回读不符（\(String(format: "0x%04X", actual))）。"
            }
        }
    }
}
