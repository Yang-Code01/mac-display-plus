import AppKit
import CoreAudio
import Foundation

/// Per-display software volume and mute.
///
/// The volume row has three possible kinds of backend per display — DDC/CI on the
/// panel, the display's own audio device, and a software mixer — and falls back down
/// that list. This file covers the last two: the system audio device that macOS
/// associates with the display, driven through its own
/// `kAudioDevicePropertyVolumeScalar`.
///
/// Why not use `NSSound`/`osascript`: both change the *system* default output, which
/// is a global side effect. Setting the scalar on the device object only touches the
/// device that belongs to this display.
enum AudioService {
    struct Device {
        let objectID: AudioDeviceID
        let name: String
        /// 0 = stereo master, 1 = left, 2 = right. Empty means the device has no
        /// usable scalar control (some USB DACs only take decibels).
        let channels: [UInt32]
        let canMute: Bool
    }

    // MARK: - Device discovery

    /// Every audio device that can play, paired with the transport type that tells
    /// us whether it plausibly belongs to an external display.
    static func outputDevices() -> [Device] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else {
            return []
        }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else {
            return []
        }
        return ids.compactMap { describe($0) }
    }

    private static func describe(_ id: AudioDeviceID) -> Device? {
        // Output streams only: an input-only device has no volume to drive.
        var streamAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var streamSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &streamAddress, 0, nil, &streamSize) == noErr, streamSize > 0 else {
            return nil
        }

        let name = string(id, kAudioObjectPropertyName) ?? "Audio \(id)"
        var channels: [UInt32] = []
        // Master first, then the per-channel elements that actually exist.
        if hasScalar(id, element: kAudioObjectPropertyElementMain) {
            channels.append(kAudioObjectPropertyElementMain)
        } else {
            for element in UInt32(1)...UInt32(2) where hasScalar(id, element: element) {
                channels.append(element)
            }
        }

        var muteAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        let canMute = AudioObjectHasProperty(id, &muteAddress)

        return Device(objectID: id, name: name, channels: channels, canMute: canMute)
    }

    private static func hasScalar(_ id: AudioDeviceID, element: UInt32) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: element
        )
        var settable: DarwinBoolean = false
        guard AudioObjectHasProperty(id, &address) else { return false }
        guard AudioObjectIsPropertySettable(id, &address, &settable) == noErr else { return false }
        return settable.boolValue
    }

    private static func string(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer -> OSStatus in
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, pointer)
        }
        return status == noErr ? (value as String) : nil
    }

    // MARK: - Reading and writing

    static func level(of device: Device) -> Double? {
        guard !device.channels.isEmpty else { return nil }
        var total = 0.0
        var found = 0
        for element in device.channels {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: element
            )
            var value: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(device.objectID, &address, 0, nil, &size, &value) == noErr {
                total += Double(value)
                found += 1
            }
        }
        return found > 0 ? total / Double(found) : nil
    }

    @discardableResult
    static func setLevel(_ level: Double, on device: Device) -> Bool {
        var wrote = false
        let clamped = Float32(max(0, min(1, level)))
        for element in device.channels {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: element
            )
            var value = clamped
            let size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectSetPropertyData(device.objectID, &address, 0, nil, size, &value) == noErr {
                wrote = true
            }
        }
        // Setting a channel does not un-mute the device on every driver; doing it
        // explicitly is what makes "drag up from zero" actually make sound.
        if wrote, clamped > 0, isMuted(device) { _ = setMuted(false, on: device) }
        return wrote
    }

    static func isMuted(_ device: Device) -> Bool {
        guard device.canMute else { return false }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device.objectID, &address, 0, nil, &size, &value) == noErr else { return false }
        return value != 0
    }

    @discardableResult
    static func setMuted(_ muted: Bool, on device: Device) -> Bool {
        guard device.canMute else { return false }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = muted ? 1 : 0
        return AudioObjectSetPropertyData(device.objectID, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr
    }

    /// The audio device macOS most plausibly routes this display through.
    ///
    /// There is no public mapping from `CGDirectDisplayID` to an audio device, so the
    /// pairing is inferred from the transport the display reports: HDMI and
    /// DisplayPort displays carry their audio on an "HDMI" transport device. When no
    /// device matches, the default output is used — which is what the user hears when
    /// they press the volume keys today.
    static func audioDevice(for displayName: String, isBuiltIn: Bool) -> Device? {
        let devices = outputDevices()
        guard !devices.isEmpty else { return nil }
        if isBuiltIn {
            return devices.first { $0.name.localizedCaseInsensitiveContains("MacBook") } ?? defaultOutputDevice()
        }
        let external = devices.filter {
            let name = $0.name.lowercased()
            return name.contains("hdmi") || name.contains("displayport") || name.contains("display")
        }
        if external.count == 1 { return external[0] }
        if let match = external.first(where: { $0.name.localizedCaseInsensitiveContains(displayName) }) { return match }
        // No display-like device at all: this panel has no audio path (no speakers, no
        // HDMI audio in the mode table). Falling back to the default output here is what
        // made the external display's volume row drive a pair of AirPods — a control that
        // moves a number belonging to something else is worse than a row that says so.
        return external.first
    }

    static func defaultOutputDevice() -> Device? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr else {
            return nil
        }
        return describe(id)
    }
}
