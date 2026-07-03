import Foundation
import IOKit
import IOKit.usb

/// Detects whether an RTL2832U-based RTL-SDR dongle is attached to USB.
/// Ported from LocalRadio's `checkForRTLSDRUSBDevice` (AppDelegate).
enum RTLSDRUSBDevice {
    /// Realtek Semiconductor Corp. vendor ID.
    private static let vendorID = 0x0bda
    /// RTL2832U product IDs: 0x2838 (generic RTL2832U), 0x2832 (OEM).
    private static let productIDs = [0x2838, 0x2832]

    /// True when an RTL-SDR USB device is currently attached. Checks both the
    /// modern (IOUSBHostDevice) and legacy (IOUSBDevice) registry classes.
    static func isConnected() -> Bool {
        for productID in productIDs {
            for className in ["IOUSBHostDevice", kIOUSBDeviceClassName] {
                if matchExists(className: className, vendorID: vendorID, productID: productID) {
                    return true
                }
            }
        }
        return false
    }

    private static func matchExists(className: String, vendorID: Int, productID: Int) -> Bool {
        guard let matching = IOServiceMatching(className) else { return false }
        let dict = matching as NSMutableDictionary
        dict[kUSBVendorID] = vendorID
        dict[kUSBProductID] = productID

        var iterator: io_iterator_t = 0
        // IOServiceGetMatchingServices consumes the matching dictionary reference.
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return false
        }
        defer { IOObjectRelease(iterator) }

        let device = IOIteratorNext(iterator)
        if device != 0 {
            IOObjectRelease(device)
            return true
        }
        return false
    }
}
