import Foundation

// Protocol constants and value types for the Link's UVC control channel.
// Sources: investigation-findings.md §2 (transport + encoding), §2.1 (XU selector
// table), §4 (verified control reference).

/// USB identity of the Insta360 Link. The camera has no USB serial string;
/// match by VID/PID only (XU 9 selector 0x03 carries per-unit identity).
enum LinkUSB {
    static let vendorID = 0x2E1A
    static let productID = 0x4C01
}

/// UVC class-specific request codes (UVC spec §4.2.1).
enum UVCRequest: UInt8 {
    case setCurrent = 0x01     // SET_CUR
    case getCurrent = 0x81     // GET_CUR
    case getMin = 0x82         // GET_MIN
    case getMax = 0x83         // GET_MAX
    case getResolution = 0x84  // GET_RES
    case getLength = 0x85      // GET_LEN
    case getInfo = 0x86        // GET_INFO
    case getDefault = 0x87     // GET_DEF
}

/// Entities on the Link's VideoControl interface 0 (§2).
enum UVCEntity: UInt8 {
    case cameraTerminal = 1
    case processingUnit = 5
    /// Vendor XU `FAF1672D-B71B-4793-8C91-7B1C9B7F95F8` — PTZ, resolution,
    /// exposure, device info. The one the first-party app drives.
    case extensionUnit = 9
    /// Vendor XU `E307E649-4618-A3FF-82FC-2D8B5F216773` — purpose unknown.
    case extensionUnit2 = 10
    /// Vendor XU `A8BD5DF2-1A98-474E-8DD0-D92672D194FA` — purpose unknown.
    case extensionUnit3 = 11
}

/// Camera Terminal (entity 1) selectors, read-verified on this unit (§4).
enum CameraTerminalSelector: UInt8 {
    case focusAbsolute = 0x06    // 2 B, 0-100, writable when auto focus is off
    case focusAuto = 0x08        // 1 B, 0/1
    case zoomAbsolute = 0x0B     // 2 B, 100-400 = 1.00x-4.00x
    case panTiltAbsolute = 0x0D  // 8 B, two int32 LE arc-seconds
    case rollAbsolute = 0x0F     // 2 B, -100...100
}

/// Processing Unit (entity 5) selectors, read-verified on this unit (§4).
enum ProcessingUnitSelector: UInt8 {
    case brightness = 0x02              // 2 B, 0-100, default 50
    case contrast = 0x03                // 2 B, 0-100, default 50
    case powerLineFrequency = 0x05      // 1 B, 0-3 (anti-flicker)
    case hue = 0x06                     // 2 B, -15...15
    case saturation = 0x07              // 2 B, 0-100, default 50
    case sharpness = 0x08               // 2 B, 0-100, default 50
    case whiteBalanceTemperature = 0x0A      // 2 B, 2000-10000 K, default 6400
    case whiteBalanceTemperatureAuto = 0x0B  // 1 B, 0/1
}

/// XU 9 selectors with numeric values confirmed by the prior project and the
/// live probe (§2.1). Other named selectors exist but their numbers are
/// unverified; probe with GET_LEN/GET_INFO before adding them here.
enum ExtensionUnitSelector: UInt8 {
    case deviceIdentity = 0x03   // 170 B blob: serial, UUID, firmware (GET only)
    case deviceName = 0x0C       // 32 B ASCII (GET only)
    case panTiltRelative = 0x16  // 4 B [panDir, panSpeed, tiltDir, tiltSpeed]
    case gimbalCenter = 0x1A     // absolute position, two int32 LE {tilt, pan};
                                 // eight zero bytes is "move to (0, 0)", i.e. center
    case videoResolution = 0x1C  // 10 B {u32 w, u32 h, u16 fps}, read-only in practice:
                                 // it reports the format the host negotiated (§9)
}

/// Direction byte for XU relative pan/tilt (§4).
enum GimbalDirection: UInt8, Sendable {
    case stop = 0x00
    case positive = 0x01
    case negative = 0xFF
}

/// PU_POWER_LINE_FREQUENCY values. The camera reports a 0-3 range; the
/// first-party app labels its anti-flicker choices Auto / 50 Hz / 60 Hz.
enum PowerLineFrequency: UInt8, Sendable {
    case disabled = 0
    case hz50 = 1
    case hz60 = 2
    case auto = 3
}

/// Absolute gimbal position in UVC arc-second units (3600 per degree).
/// Verified range on this unit: pan ±522000 (±145°), tilt -324000...360000
/// (-90°...+100°), resolution 3600 (1°). Direction sign is unverified on
/// hardware (§9) — do not bake sign assumptions in above this layer.
struct PanTiltPosition: Equatable, Sendable {
    static let arcSecondsPerDegree = 3600.0

    var pan: Int32
    var tilt: Int32

    var panDegrees: Double { Double(pan) / Self.arcSecondsPerDegree }
    var tiltDegrees: Double { Double(tilt) / Self.arcSecondsPerDegree }

    init(pan: Int32, tilt: Int32) {
        self.pan = pan
        self.tilt = tilt
    }

    init(panDegrees: Double, tiltDegrees: Double) {
        self.init(pan: Int32(panDegrees * Self.arcSecondsPerDegree),
                  tilt: Int32(tiltDegrees * Self.arcSecondsPerDegree))
    }

    /// Wire format: two int32 LE (pan then tilt).
    init(uvcBytes bytes: [UInt8]) {
        precondition(bytes.count >= 8, "pan/tilt payload must be 8 bytes")
        self.init(pan: Int32(littleEndianBytes: Array(bytes[0..<4])),
                  tilt: Int32(littleEndianBytes: Array(bytes[4..<8])))
    }

    var uvcBytes: [UInt8] { pan.littleEndianBytes + tilt.littleEndianBytes }
}

/// XU 9 selector 0x1C payload: {u32 width, u32 height, u16 fps} LE (§2.1).
struct VideoMode: Equatable, Sendable {
    var width: UInt32
    var height: UInt32
    var framesPerSecond: UInt16
}

/// MIN/MAX/RES/DEF for one numeric control, as reported by the device.
struct UVCControlRange<Value: FixedWidthInteger & Sendable>: Sendable {
    var minimum: Value
    var maximum: Value
    var resolution: Value
    var defaultValue: Value
}

enum UVCError: Error, CustomStringConvertible {
    case deviceNotFound
    case pluginCreationFailed(Int32)
    case interfaceQueryFailed(Int32)
    case transferFailed(request: UInt8, entity: UInt8, selector: UInt8, code: Int32)
    case shortResponse(expected: Int, received: Int)
    case unexpectedResponse(entity: UInt8, selector: UInt8, bytes: [UInt8])

    /// The device has stopped answering, as opposed to rejecting one control.
    ///
    /// A batch of writes — a preset restore is roughly a dozen — should stop at
    /// the first of these rather than reporting the same failure a dozen times.
    /// That mattered less when a wedged transfer hung forever and the batch
    /// never got past its first write. Now that transfers time out
    /// (`USBDeviceHandle`), carrying on costs the full timeout per remaining
    /// control, turning one stuck camera into a restore that grinds for over a
    /// minute before reporting.
    ///
    /// Codes are literals because this file deliberately imports only
    /// Foundation, so the standalone checks can compile it without IOKit. From
    /// IOUSBLib.h and IOKit/IOReturn.h.
    var stopsBatch: Bool {
        switch self {
        case .deviceNotFound:
            true
        case .transferFailed(_, _, _, let code):
            switch UInt32(bitPattern: code) {
            case 0xe000_4051,  // kIOUSBTransactionTimeout
                 0xe000_02d6,  // kIOReturnTimeout
                 0xe000_02ed,  // kIOReturnNotResponding
                 0xe000_02c0:  // kIOReturnNoDevice
                true
            default:
                false
            }
        default:
            false
        }
    }

    var description: String {
        switch self {
        case .deviceNotFound:
            "Insta360 Link not found (VID 0x2E1A / PID 0x4C01)"
        case .pluginCreationFailed(let code):
            String(format: "IOKit plug-in creation failed: 0x%08x", code)
        case .interfaceQueryFailed(let code):
            String(format: "USB device interface query failed: 0x%08x", code)
        case .transferFailed(let request, let entity, let selector, let code):
            String(format: "UVC request 0x%02x failed (entity %d, selector 0x%02x): 0x%08x",
                   request, entity, selector, code)
        case .shortResponse(let expected, let received):
            "Short UVC response: expected \(expected) bytes, got \(received)"
        case .unexpectedResponse(let entity, let selector, let bytes):
            String(format: "Unexpected UVC response (entity %d, selector 0x%02x): %@",
                   entity, selector, bytes.map { String(format: "%02x", $0) }.joined())
        }
    }
}

// Little-endian wire codec for the fixed-width integers UVC controls carry.
extension FixedWidthInteger {
    var littleEndianBytes: [UInt8] {
        withUnsafeBytes(of: littleEndian) { Array($0) }
    }

    init(littleEndianBytes bytes: [UInt8]) {
        precondition(bytes.count >= MemoryLayout<Self>.size)
        var value = Self.zero
        withUnsafeMutableBytes(of: &value) {
            $0.copyBytes(from: bytes.prefix(MemoryLayout<Self>.size))
        }
        self = Self(littleEndian: value)
    }
}
