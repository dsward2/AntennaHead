import Foundation
import librtlsdr

struct RTLSDRDevice: Codable, Equatable {
    let index: UInt32
    let name: String
    let manufacturer: String
    let product: String
    let serial: String
}

/// Enumerates connected RTL-SDR USB devices using the librtlsdr API
/// (mirrors rtl_convenience.c's verbose_device_search pattern).
enum RTLSDRDeviceList {
    /// Returns the current list of detected RTL-SDR devices.
    /// Blocks briefly for libusb enumeration; call off the main thread.
    /// If the device is already open by a subprocess, USB string reads
    /// may fail (rc != 0) — the device is still listed with an empty serial.
    nonisolated static func enumerate() -> [RTLSDRDevice] {
        let count = rtlsdr_get_device_count()
        guard count > 0 else { return [] }
        return (0..<count).map { index in
            let name: String
            if let ptr = rtlsdr_get_device_name(index) {
                name = String(cString: ptr)
            } else {
                name = "RTL-SDR Device"
            }

            var mfr  = [CChar](repeating: 0, count: 256)
            var prod = [CChar](repeating: 0, count: 256)
            var ser  = [CChar](repeating: 0, count: 256)
            let rc = rtlsdr_get_device_usb_strings(index, &mfr, &prod, &ser)
            if rc == 0 {
                return RTLSDRDevice(
                    index: index,
                    name: name,
                    manufacturer: String(cString: mfr),
                    product: String(cString: prod),
                    serial: String(cString: ser)
                )
            }
            return RTLSDRDevice(index: index, name: name, manufacturer: "", product: "", serial: "")
        }
    }
}
