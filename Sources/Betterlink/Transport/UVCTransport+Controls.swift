import Foundation

// Typed API for every control verified in investigation-findings.md §4, plus
// the known XU 9 selectors. Setters clamp to the ranges read from this unit so
// a UI bug cannot send the camera an out-of-range value. Of the XU selectors
// beyond 0x16/0x1A, only the 0x1C video-mode write is exposed (for the
// Dashboard picker) and it is still unverified on hardware (§9).

// MARK: - Camera Terminal (entity 1)

extension UVCTransport {
    /// CT_ZOOM_ABSOLUTE: 100...400 = 1.00x...4.00x, step 10 = 0.1x.
    func zoom() throws -> UInt16 {
        try read(entity: .cameraTerminal, selector: CameraTerminalSelector.zoomAbsolute.rawValue)
    }

    func setZoom(_ value: UInt16) throws {
        try write(value.clamped(to: 100...400), entity: .cameraTerminal,
                  selector: CameraTerminalSelector.zoomAbsolute.rawValue)
    }

    func zoomRange() throws -> UVCControlRange<UInt16> {
        try range(entity: .cameraTerminal, selector: CameraTerminalSelector.zoomAbsolute.rawValue)
    }

    /// CT_PANTILT_ABSOLUTE, readable — the basis for position presets.
    func panTilt() throws -> PanTiltPosition {
        PanTiltPosition(uvcBytes: try get(.getCurrent, entity: .cameraTerminal,
                                          selector: CameraTerminalSelector.panTiltAbsolute.rawValue,
                                          length: 8))
    }

    /// Not clamped here: limits are device-reported (use `panTiltLimits()`).
    /// Signs are hardware-verified: pan rises to the right, tilt rises upward.
    /// Do not follow this with a roll write — that aborts the move and sends
    /// the head back where it started (§9). Settle time is not yet measured.
    func setPanTilt(_ position: PanTiltPosition) throws {
        try set(entity: .cameraTerminal,
                selector: CameraTerminalSelector.panTiltAbsolute.rawValue,
                payload: position.uvcBytes)
    }

    func panTiltLimits() throws -> (minimum: PanTiltPosition, maximum: PanTiltPosition,
                                    resolution: PanTiltPosition) {
        let selector = CameraTerminalSelector.panTiltAbsolute.rawValue
        return (
            minimum: PanTiltPosition(uvcBytes: try get(.getMin, entity: .cameraTerminal,
                                                       selector: selector, length: 8)),
            maximum: PanTiltPosition(uvcBytes: try get(.getMax, entity: .cameraTerminal,
                                                       selector: selector, length: 8)),
            resolution: PanTiltPosition(uvcBytes: try get(.getResolution, entity: .cameraTerminal,
                                                          selector: selector, length: 8)))
    }

    /// CT_ROLL_ABSOLUTE: -100...100 (the app's "horizontal fine-tuning").
    func roll() throws -> Int16 {
        try read(entity: .cameraTerminal, selector: CameraTerminalSelector.rollAbsolute.rawValue)
    }

    func setRoll(_ value: Int16) throws {
        try write(value.clamped(to: -100...100), entity: .cameraTerminal,
                  selector: CameraTerminalSelector.rollAbsolute.rawValue)
    }

    func rollRange() throws -> UVCControlRange<Int16> {
        try range(entity: .cameraTerminal, selector: CameraTerminalSelector.rollAbsolute.rawValue)
    }

    /// CT_FOCUS_ABSOLUTE: 0...100, writable only while auto focus is off.
    func focus() throws -> UInt16 {
        try read(entity: .cameraTerminal, selector: CameraTerminalSelector.focusAbsolute.rawValue)
    }

    func focusRange() throws -> UVCControlRange<UInt16> {
        try range(entity: .cameraTerminal, selector: CameraTerminalSelector.focusAbsolute.rawValue)
    }

    func setFocus(_ value: UInt16) throws {
        try write(value.clamped(to: 0...100), entity: .cameraTerminal,
                  selector: CameraTerminalSelector.focusAbsolute.rawValue)
    }

    func isAutoFocusEnabled() throws -> Bool {
        try read(UInt8.self, entity: .cameraTerminal,
                 selector: CameraTerminalSelector.focusAuto.rawValue) != 0
    }

    func setAutoFocus(_ enabled: Bool) throws {
        try write(UInt8(enabled ? 1 : 0), entity: .cameraTerminal,
                  selector: CameraTerminalSelector.focusAuto.rawValue)
    }
}

// MARK: - Processing Unit (entity 5)

extension UVCTransport {
    /// 0...100, default 50.
    func brightness() throws -> UInt16 { try readPU(.brightness) }
    func setBrightness(_ value: UInt16) throws { try writePU(.brightness, value.clamped(to: 0...100)) }
    func brightnessRange() throws -> UVCControlRange<UInt16> { try rangePU(.brightness) }

    /// 0...100, default 50.
    func contrast() throws -> UInt16 { try readPU(.contrast) }
    func setContrast(_ value: UInt16) throws { try writePU(.contrast, value.clamped(to: 0...100)) }
    func contrastRange() throws -> UVCControlRange<UInt16> { try rangePU(.contrast) }

    /// 0...100, default 50.
    func saturation() throws -> UInt16 { try readPU(.saturation) }
    func setSaturation(_ value: UInt16) throws { try writePU(.saturation, value.clamped(to: 0...100)) }
    func saturationRange() throws -> UVCControlRange<UInt16> { try rangePU(.saturation) }

    /// 0...100, default 50.
    func sharpness() throws -> UInt16 { try readPU(.sharpness) }
    func setSharpness(_ value: UInt16) throws { try writePU(.sharpness, value.clamped(to: 0...100)) }
    func sharpnessRange() throws -> UVCControlRange<UInt16> { try rangePU(.sharpness) }

    /// -15...15 (present on the camera, not surfaced by the first-party app).
    func hue() throws -> Int16 {
        try read(entity: .processingUnit, selector: ProcessingUnitSelector.hue.rawValue)
    }

    func hueRange() throws -> UVCControlRange<Int16> {
        try range(entity: .processingUnit, selector: ProcessingUnitSelector.hue.rawValue)
    }

    func setHue(_ value: Int16) throws {
        try write(value.clamped(to: -15...15), entity: .processingUnit,
                  selector: ProcessingUnitSelector.hue.rawValue)
    }

    /// 2000...10000 K in 50 K steps, default 6400; applies while auto WB is off.
    func whiteBalanceTemperature() throws -> UInt16 { try readPU(.whiteBalanceTemperature) }

    func whiteBalanceTemperatureRange() throws -> UVCControlRange<UInt16> {
        try rangePU(.whiteBalanceTemperature)
    }

    func setWhiteBalanceTemperature(_ kelvin: UInt16) throws {
        try writePU(.whiteBalanceTemperature, kelvin.clamped(to: 2000...10000))
    }

    func isAutoWhiteBalanceEnabled() throws -> Bool {
        try read(UInt8.self, entity: .processingUnit,
                 selector: ProcessingUnitSelector.whiteBalanceTemperatureAuto.rawValue) != 0
    }

    func setAutoWhiteBalance(_ enabled: Bool) throws {
        try write(UInt8(enabled ? 1 : 0), entity: .processingUnit,
                  selector: ProcessingUnitSelector.whiteBalanceTemperatureAuto.rawValue)
    }

    /// Anti-flicker in the first-party app.
    func powerLineFrequency() throws -> PowerLineFrequency {
        let raw = try read(UInt8.self, entity: .processingUnit,
                           selector: ProcessingUnitSelector.powerLineFrequency.rawValue)
        guard let frequency = PowerLineFrequency(rawValue: raw) else {
            throw UVCError.unexpectedResponse(entity: UVCEntity.processingUnit.rawValue,
                                              selector: ProcessingUnitSelector.powerLineFrequency.rawValue,
                                              bytes: [raw])
        }
        return frequency
    }

    func setPowerLineFrequency(_ frequency: PowerLineFrequency) throws {
        try write(frequency.rawValue, entity: .processingUnit,
                  selector: ProcessingUnitSelector.powerLineFrequency.rawValue)
    }

    private func readPU(_ selector: ProcessingUnitSelector) throws -> UInt16 {
        try read(entity: .processingUnit, selector: selector.rawValue)
    }

    private func writePU(_ selector: ProcessingUnitSelector, _ value: UInt16) throws {
        try write(value, entity: .processingUnit, selector: selector.rawValue)
    }

    private func rangePU(_ selector: ProcessingUnitSelector) throws -> UVCControlRange<UInt16> {
        try range(entity: .processingUnit, selector: selector.rawValue)
    }
}

// MARK: - Extension Unit 9 (vendor)

extension UVCTransport {
    static let maxPanSpeed: UInt8 = 30
    static let maxTiltSpeed: UInt8 = 20

    /// Relative pan/tilt drive (XU 0x16). The camera keeps moving until told
    /// to stop. Quirk (§7): a nonzero direction with speed 0 makes the gimbal
    /// creep, so a zero speed is normalized to (stop, 1) per axis. The prior
    /// CLI's direction sign was inverted vs its own docs — trust hardware.
    func driveGimbal(pan: GimbalDirection, panSpeed: UInt8,
                     tilt: GimbalDirection, tiltSpeed: UInt8) throws {
        let (panDir, panSpd) = Self.normalized(pan, panSpeed, max: Self.maxPanSpeed)
        let (tiltDir, tiltSpd) = Self.normalized(tilt, tiltSpeed, max: Self.maxTiltSpeed)
        try set(entity: .extensionUnit,
                selector: ExtensionUnitSelector.panTiltRelative.rawValue,
                payload: [panDir.rawValue, panSpd, tiltDir.rawValue, tiltSpd])
    }

    /// Stop all gimbal movement. The stop payload is [0, 1, 0, 1] — stopped
    /// direction with speed 1 on both axes — never all zeros (§7).
    func stopGimbal() throws {
        try driveGimbal(pan: .stop, panSpeed: 1, tilt: .stop, tiltSpeed: 1)
    }

    /// Re-center the gimbal (XU 0x1A), then stop — the prior project found the
    /// gimbal can keep drifting after a center without an explicit stop (§7).
    /// If the trailing stop throws (device dropped mid-sequence), callers
    /// should retry `stopGimbal()` once reconnected, or the drift can persist.
    func centerGimbal() throws {
        try set(entity: .extensionUnit,
                selector: ExtensionUnitSelector.gimbalCenter.rawValue,
                payload: [UInt8](repeating: 0, count: 8))
        try stopGimbal()
    }

    /// Current video mode (XU 0x1C, read side — verified against the live
    /// camera, §4). Read-only on purpose: the write side is a hardware-verified
    /// no-op (2026-08-21, §9) — the selector reports the format the *host*
    /// negotiated (all zeros when nothing is streaming), so resolution and frame
    /// rate are an `AVCaptureDevice.activeFormat` choice. Do not add a setter.
    func videoMode() throws -> VideoMode {
        let bytes = try get(.getCurrent, entity: .extensionUnit,
                            selector: ExtensionUnitSelector.videoResolution.rawValue,
                            length: 10)
        return VideoMode(width: UInt32(littleEndianBytes: Array(bytes[0..<4])),
                         height: UInt32(littleEndianBytes: Array(bytes[4..<8])),
                         framesPerSecond: UInt16(littleEndianBytes: Array(bytes[8..<10])))
    }

    /// On-screen device name (XU 0x0C), e.g. "IBJLA24053R34Y". The camera has
    /// no USB serial string, so this is its per-unit identity.
    func deviceName() throws -> String {
        let bytes = try get(.getCurrent, entity: .extensionUnit,
                            selector: ExtensionUnitSelector.deviceName.rawValue,
                            length: 32)
        let ascii = bytes.prefix { $0 != 0 }
        return String(decoding: ascii, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalized(_ direction: GimbalDirection, _ speed: UInt8,
                                   max: UInt8) -> (GimbalDirection, UInt8) {
        if direction == .stop || speed == 0 { return (.stop, 1) }
        return (direction, min(speed, max))
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
