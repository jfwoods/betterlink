import Foundation

// Hardware probe for the two gimbal debts found in the 2026-08-21 smoke test
// (ROADMAP §9): relative tilt (XU 9 sel 0x16) does nothing, and the
// CT_PANTILT_ABSOLUTE write is a no-op. Not part of the app target and not run
// in CI — it needs the Link attached. Build and run it with the bare toolchain:
//
//   swiftc -swift-version 6 -parse-as-library \
//     Sources/Betterlink/Transport/UVCTypes.swift \
//     Sources/Betterlink/Transport/USBDeviceHandle.swift \
//     Sources/Betterlink/Transport/UVCTransport.swift \
//     Checks/GimbalProbe.swift -o /tmp/gimbal-probe
//
//   /tmp/gimbal-probe scan            # GET_LEN/GET_INFO for every XU 9 selector
//   /tmp/gimbal-probe pos             # current CT_PANTILT_ABSOLUTE reading
//   /tmp/gimbal-probe watch 10        # poll position for N seconds
//   /tmp/gimbal-probe get 9 0x17 8    # raw GET_CUR
//   /tmp/gimbal-probe set 9 0x16 00 01 01 0a   # raw SET_CUR, prints position delta
//
// Quit the app before running this: the camera is one physical resource.

@main
struct GimbalProbe {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard let command = arguments.first else {
            print("usage: gimbal-probe scan | pos | watch <seconds> | get <entity> <sel> <len> | set <entity> <sel> <bytes…>")
            return
        }
        let transport = UVCTransport()
        do {
            try await transport.connect()
            switch command {
            case "scan": try await scan(transport)
            case "pos": print(try await position(transport))
            case "watch": try await watch(transport, seconds: Double(arguments[1]) ?? 5)
            case "get":
                let bytes = try await transport.get(.getCurrent,
                                                    entity: entity(arguments[1]),
                                                    selector: byte(arguments[2]),
                                                    length: Int(arguments[3]) ?? 1)
                print(hex(bytes))
            case "set":
                let payload = arguments.dropFirst(3).map(byte)
                let before = try await position(transport)
                try await transport.set(entity: entity(arguments[1]),
                                        selector: byte(arguments[2]),
                                        payload: payload)
                try await Task.sleep(for: .milliseconds(1200))
                let after = try await position(transport)
                print("sent \(hex(payload))\n  before \(before)\n  after  \(after)")
            default: print("unknown command \(command)")
            }
        } catch {
            print("FAILED: \(error)")
            exit(1)
        }
    }

    /// GET_LEN + GET_INFO for every XU 9 selector, plus GET_CUR where the
    /// control says it supports GET. All reads — nothing is written.
    private static func scan(_ transport: UVCTransport) async throws {
        print("sel  len  info  get")
        for selector in UInt8(1)...UInt8(0x20) {
            guard let length = try? await transport.length(entity: .extensionUnit, selector: selector),
                  let info = try? await transport.info(entity: .extensionUnit, selector: selector)
            else { continue }
            var value = ""
            if info & 0x01 != 0, length <= 64,
               let bytes = try? await transport.get(.getCurrent, entity: .extensionUnit,
                                                    selector: selector, length: Int(length)) {
                value = hex(bytes)
            }
            let capability = [info & 0x01 != 0 ? "GET" : "", info & 0x02 != 0 ? "SET" : ""]
                .filter { !$0.isEmpty }.joined(separator: "+")
            print(String(format: "0x%02X %4d  %-7@ %@", selector, Int(length),
                         capability as NSString, value as NSString))
        }
    }

    private static func watch(_ transport: UVCTransport, seconds: Double) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        var last = ""
        while Date() < deadline {
            let now = try await position(transport)
            if now != last { print(now); last = now }
            try await Task.sleep(for: .milliseconds(250))
        }
    }

    private static func position(_ transport: UVCTransport) async throws -> String {
        let bytes = try await transport.get(.getCurrent, entity: .cameraTerminal,
                                            selector: CameraTerminalSelector.panTiltAbsolute.rawValue,
                                            length: 8)
        let pan = Int32(littleEndianBytes: Array(bytes[0..<4]))
        let tilt = Int32(littleEndianBytes: Array(bytes[4..<8]))
        return String(format: "pan %+8d (%+6.1f°)  tilt %+8d (%+6.1f°)",
                      pan, Double(pan) / 3600, tilt, Double(tilt) / 3600)
    }

    private static func entity(_ text: String) -> UVCEntity {
        UVCEntity(rawValue: byte(text)) ?? .extensionUnit
    }

    /// Always hex — every byte on this wire is written in hex, and a decimal
    /// reading silently turns "73" into 0x49.
    private static func byte(_ text: String) -> UInt8 {
        UInt8(text.hasPrefix("0x") ? String(text.dropFirst(2)) : text, radix: 16) ?? 0
    }

    private static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}
