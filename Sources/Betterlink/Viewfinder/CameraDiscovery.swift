import AVFoundation

/// Finds the Insta360 Link among the attached cameras.
///
/// The macOS UVC driver keeps the Link available as a normal external camera, so
/// discovery is plain AVFoundation. macOS embeds the USB vendor/product IDs in an
/// external camera's `modelID` (decimal, e.g. "UVC Camera VendorID_11802
/// ProductID_19457") and usually in its `uniqueID` (hex). Matching checks both,
/// with the marketing name as a last resort.
enum LinkCamera {
    /// USB identity of the Insta360 Link (investigation-findings.md section 2).
    static let vendorID = 0x2E1A
    static let productID = 0x4C01

    /// Discovery session covering every camera the viewfinder could show.
    /// Kept alive by the caller so connect/disconnect updates keep flowing.
    static func discoverySession() -> AVCaptureDevice.DiscoverySession {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external, .continuityCamera],
            mediaType: .video,
            position: .unspecified
        )
    }

    static func isLink(_ device: AVCaptureDevice) -> Bool {
        let model = device.modelID
        if model.contains("VendorID_\(vendorID)"), model.contains("ProductID_\(productID)") {
            return true
        }
        let unique = device.uniqueID.lowercased()
        if unique.contains(String(format: "%04x", vendorID)), unique.contains(String(format: "%04x", productID)) {
            return true
        }
        return device.localizedName.localizedCaseInsensitiveContains("Insta360 Link")
    }

    /// The Link if present, otherwise any external camera so the viewfinder stays useful.
    static func bestCamera(in devices: [AVCaptureDevice]) -> AVCaptureDevice? {
        devices.first(where: isLink)
            ?? devices.first { $0.deviceType == .external }
            ?? devices.first
    }
}
