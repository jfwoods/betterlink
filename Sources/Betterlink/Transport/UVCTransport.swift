import Foundation

/// The single owner of the camera's control channel. Every EP0 transfer in the
/// app goes through this actor, which serializes them (the camera is one
/// physical resource) and handles the connection lifecycle: transfers lazily
/// open the device, and any failed transfer drops the handle so the next call
/// re-discovers the camera — the carry-over behavior from the prior project
/// (investigation-findings.md §7).
actor UVCTransport {
    private var handle: USBDeviceHandle?

    var isConnected: Bool { handle != nil }

    /// Finds and opens the camera now instead of on first transfer.
    /// Throws `UVCError.deviceNotFound` if no Link is attached.
    func connect() throws {
        _ = try openIfNeeded()
    }

    func disconnect() {
        handle = nil
    }

    // MARK: Raw transfers

    /// GET_CUR / GET_MIN / GET_MAX / GET_RES / GET_LEN / GET_INFO / GET_DEF.
    func get(_ request: UVCRequest, entity: UVCEntity, selector: UInt8,
             length: Int) throws -> [UInt8] {
        try perform { try $0.uvcGet(request, entity: entity.rawValue,
                                    selector: selector, length: length) }
    }

    /// SET_CUR. Writes to the camera — the write side of several XU selectors
    /// is unverified on hardware (§9); stick to the typed API where possible.
    func set(entity: UVCEntity, selector: UInt8, payload: [UInt8]) throws {
        try perform { try $0.uvcSet(entity: entity.rawValue, selector: selector,
                                    payload: payload) }
    }

    // MARK: Typed integer transfers (little-endian, as UVC encodes them)

    func read<Value: FixedWidthInteger & Sendable>(
        _ type: Value.Type = Value.self, _ request: UVCRequest = .getCurrent,
        entity: UVCEntity, selector: UInt8
    ) throws -> Value {
        Value(littleEndianBytes: try get(request, entity: entity, selector: selector,
                                         length: MemoryLayout<Value>.size))
    }

    func write<Value: FixedWidthInteger & Sendable>(
        _ value: Value, entity: UVCEntity, selector: UInt8
    ) throws {
        try set(entity: entity, selector: selector, payload: value.littleEndianBytes)
    }

    /// The device-reported MIN/MAX/RES/DEF for a numeric control.
    func range<Value: FixedWidthInteger & Sendable>(
        _ type: Value.Type = Value.self, entity: UVCEntity, selector: UInt8
    ) throws -> UVCControlRange<Value> {
        UVCControlRange(
            minimum: try read(Value.self, .getMin, entity: entity, selector: selector),
            maximum: try read(Value.self, .getMax, entity: entity, selector: selector),
            resolution: try read(Value.self, .getResolution, entity: entity, selector: selector),
            defaultValue: try read(Value.self, .getDefault, entity: entity, selector: selector))
    }

    /// GET_INFO capability bitmap (D0 = GET supported, D1 = SET supported).
    /// Always check before driving an unverified selector — several XU
    /// selectors are GET-only or SET-only (§2).
    func info(entity: UVCEntity, selector: UInt8) throws -> UInt8 {
        try read(UInt8.self, .getInfo, entity: entity, selector: selector)
    }

    /// GET_LEN payload size in bytes (XU controls report this reliably even
    /// though the XU descriptors' bmControls are not trustworthy, §2).
    func length(entity: UVCEntity, selector: UInt8) throws -> UInt16 {
        try read(UInt16.self, .getLength, entity: entity, selector: selector)
    }

    // MARK: Lifecycle

    private func openIfNeeded() throws -> USBDeviceHandle {
        if let handle { return handle }
        let opened = try USBDeviceHandle.open(vendorID: LinkUSB.vendorID,
                                              productID: LinkUSB.productID)
        handle = opened
        return opened
    }

    private func perform<Result>(_ body: (USBDeviceHandle) throws -> Result) throws -> Result {
        let handle = try openIfNeeded()
        do {
            return try body(handle)
        } catch {
            // Assume the device went away; drop the handle so the next
            // transfer re-discovers it.
            self.handle = nil
            throw error
        }
    }
}
