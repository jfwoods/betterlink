import Foundation
import IOKit
import IOKit.usb
import IOKit.usb.IOUSBLib

/// Device-level handle on the camera's control endpoint (EP0).
///
/// Opens the IOUSBHostDevice registry entry's device-level user client via the
/// IOUSBLib plug-in interface and issues UVC class control transfers with
/// `DeviceRequestTO`. We deliberately never call `USBDeviceOpen` and never touch
/// interfaces 0/1: macOS `UVCAssistant` owns the video interfaces exclusively,
/// and class requests on EP0 work without opening the device, so the Link stays
/// a live webcam while we control it. This is the exact approach proven by the
/// prior `insta360link-joystick-controller` daemon (investigation-findings.md
/// §2, §7). No root, no entitlements.
///
/// Not Sendable — must stay confined to `UVCTransport`.
final class USBDeviceHandle {
    /// Version 182, not the base `IOUSBDeviceInterface`, purely because that
    /// is the oldest version exposing `DeviceRequestTO`. Everything else here
    /// is available on the base interface. IOUSBFamily 1.8.2 shipped with Mac
    /// OS X 10.0.4, so against a macOS 26 deployment target there is nothing to
    /// fall back to and no fallback path.
    private typealias DeviceInterface =
        UnsafeMutablePointer<UnsafeMutablePointer<IOUSBDeviceInterface182>?>

    /// Milliseconds. A UVC control transfer only queues the camera's work — a
    /// gimbal move completes long after the request returns — so these bound a
    /// wedged device, not a slow one, and are deliberately far looser than any
    /// healthy transfer needs.
    ///
    /// Without them a camera that stops answering blocks the `UVCTransport`
    /// actor forever, and since the whole app shares one transport, that hangs
    /// the Dashboard as surely as anything else.
    private static let noDataTimeout: UInt32 = 2_000
    private static let completionTimeout: UInt32 = 5_000

    private let device: DeviceInterface

    private init(device: DeviceInterface) {
        self.device = device
    }

    deinit {
        _ = device.pointee?.pointee.Release(UnsafeMutableRawPointer(device))
    }

    // MARK: Discovery

    /// Finds the camera by VID/PID and opens its device-level user client.
    static func open(vendorID: Int, productID: Int) throws -> USBDeviceHandle {
        let service = try findService(vendorID: vendorID, productID: productID)
        defer { IOObjectRelease(service) }

        // The IOUSBLib CFUUID constants are C macros that Swift does not
        // import; these bytes are copied from IOCFPlugIn.h / IOUSBLib.h.
        let plugInInterfaceUUID = CFUUIDGetConstantUUIDWithBytes(nil,
            0xC2, 0x44, 0xE8, 0x58, 0x10, 0x9C, 0x11, 0xD4,
            0x91, 0xD4, 0x00, 0x50, 0xE4, 0xC6, 0x42, 0x6F)
        let deviceUserClientTypeUUID = CFUUIDGetConstantUUIDWithBytes(nil,
            0x9D, 0xC7, 0xB7, 0x80, 0x9E, 0xC0, 0x11, 0xD4,
            0xA5, 0x4F, 0x00, 0x0A, 0x27, 0x05, 0x28, 0x61)
        // kIOUSBDeviceInterfaceID182, bytes copied from IOUSBLib.h. The base
        // kIOUSBDeviceInterfaceID would return an interface without
        // DeviceRequestTO.
        let deviceInterfaceUUID = CFUUIDGetConstantUUIDWithBytes(nil,
            0x15, 0x2F, 0xC4, 0x96, 0x48, 0x91, 0x11, 0xD5,
            0x9D, 0x52, 0x00, 0x0A, 0x27, 0x80, 0x1E, 0x86)

        var plugIn: UnsafeMutablePointer<UnsafeMutablePointer<IOCFPlugInInterface>?>?
        var score: Int32 = 0
        let kr = IOCreatePlugInInterfaceForService(
            service, deviceUserClientTypeUUID, plugInInterfaceUUID, &plugIn, &score)
        guard kr == kIOReturnSuccess, let plugIn else {
            throw UVCError.pluginCreationFailed(kr)
        }
        defer { _ = plugIn.pointee?.pointee.Release(UnsafeMutableRawPointer(plugIn)) }

        var raw: LPVOID?
        let result = plugIn.pointee!.pointee.QueryInterface(
            UnsafeMutableRawPointer(plugIn),
            CFUUIDGetUUIDBytes(deviceInterfaceUUID),
            &raw)
        guard result == 0, let raw else {
            throw UVCError.interfaceQueryFailed(result)
        }

        let device = raw.assumingMemoryBound(
            to: UnsafeMutablePointer<IOUSBDeviceInterface182>?.self)
        return USBDeviceHandle(device: device)
    }

    private static func findService(vendorID: Int, productID: Int) throws -> io_service_t {
        // Modern macOS registers devices as IOUSBHostDevice; IOUSBDevice is the
        // legacy compatibility name the prior project matched. Try both.
        for className in ["IOUSBHostDevice", kIOUSBDeviceClassName] {
            guard let matching = IOServiceMatching(className) else { continue }
            let dict = matching as NSMutableDictionary
            dict["idVendor"] = NSNumber(value: vendorID)
            dict["idProduct"] = NSNumber(value: productID)
            // IOServiceGetMatchingService consumes the dictionary reference.
            let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
            if service != 0 { return service }
        }
        throw UVCError.deviceNotFound
    }

    // MARK: UVC control transfers

    /// GET_* request. Returns exactly `length` bytes or throws.
    func uvcGet(_ request: UVCRequest, entity: UInt8, selector: UInt8,
                length: Int) throws -> [UInt8] {
        precondition(request != .setCurrent && length > 0)
        var data = [UInt8](repeating: 0, count: length)
        let received = try transfer(bmRequestType: 0xA1, request: request.rawValue,
                                    entity: entity, selector: selector, data: &data)
        guard received == length else {
            throw UVCError.shortResponse(expected: length, received: received)
        }
        return data
    }

    /// SET_CUR request. Like the proven C daemon, this trusts a successful
    /// return code and does not inspect wLenDone on OUT transfers.
    func uvcSet(entity: UInt8, selector: UInt8, payload: [UInt8]) throws {
        precondition(!payload.isEmpty)
        var data = payload
        _ = try transfer(bmRequestType: 0x21, request: UVCRequest.setCurrent.rawValue,
                         entity: entity, selector: selector, data: &data)
    }

    /// Wire encoding (§2): wValue = selector << 8, wIndex = entity << 8 with
    /// the low byte 0x00 addressing VideoControl interface 0. bmRequestType is
    /// class | interface recipient (0xA1 in, 0x21 out).
    private func transfer(bmRequestType: UInt8, request: UInt8,
                          entity: UInt8, selector: UInt8,
                          data: inout [UInt8]) throws -> Int {
        var req = IOUSBDevRequestTO()
        req.bmRequestType = bmRequestType
        req.bRequest = request
        req.wValue = UInt16(selector) << 8
        req.wIndex = UInt16(entity) << 8
        req.wLength = UInt16(data.count)
        req.noDataTimeout = Self.noDataTimeout
        req.completionTimeout = Self.completionTimeout

        let kr = data.withUnsafeMutableBytes { buffer in
            req.pData = buffer.baseAddress
            return device.pointee!.pointee.DeviceRequestTO(
                UnsafeMutableRawPointer(device), &req)
        }
        guard kr == kIOReturnSuccess else {
            throw UVCError.transferFailed(request: request, entity: entity,
                                          selector: selector, code: kr)
        }
        return Int(req.wLenDone)
    }
}
