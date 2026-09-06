import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation
import os

private let audioDeviceLog = Logger(subsystem: "com.felix.hushtype", category: "audio-device")

struct AudioInputDevice: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let audioObjectID: AudioDeviceID
    let isBuiltIn: Bool
    let isAlive: Bool
}

enum AudioInputSelection {
    static let followSystem = "system"
    static let automatic = "automatic"
    private static let devicePrefix = "device:"

    static func device(_ uid: String) -> String { devicePrefix + uid }

    static func deviceUID(from rawValue: String) -> String? {
        guard rawValue.hasPrefix(devicePrefix) else { return nil }
        return String(rawValue.dropFirst(devicePrefix.count))
    }
}

enum AudioInputDeviceManager {
    static func availableDevices() -> [AudioInputDevice] {
        allDeviceIDs().compactMap(makeInputDevice).sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    static func captureDevice(rawValue: String, excludingUID: String? = nil) -> AVCaptureDevice? {
        let devices = availableDevices()
        let defaultID = defaultInputDeviceID()
        let chosen = resolvedDevice(
            rawValue: rawValue,
            devices: devices,
            defaultID: defaultID,
            excludingUID: excludingUID
        )
        guard let chosen else { return nil }
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )
        let captureDevice = discovery.devices.first(where: { $0.uniqueID == chosen.id })
        if let captureDevice {
            audioDeviceLog.info("Resolved capture device: \(captureDevice.localizedName, privacy: .public)")
        }
        return captureDevice
    }

    static func currentDeviceName(rawValue: String, devices: [AudioInputDevice]? = nil) -> String? {
        let devices = devices ?? availableDevices()
        return resolvedDevice(
            rawValue: rawValue,
            devices: devices,
            defaultID: defaultInputDeviceID()
        )?.name
    }

    static func resolvedDevice(
        rawValue: String,
        devices: [AudioInputDevice],
        defaultID: AudioDeviceID?,
        excludingUID: String? = nil
    ) -> AudioInputDevice? {
        let eligible = devices.filter { $0.isAlive && $0.id != excludingUID }
        if rawValue == AudioInputSelection.automatic {
            return eligible.first(where: { $0.audioObjectID == defaultID })
                ?? eligible.first(where: { $0.isBuiltIn })
                ?? eligible.first
        }
        if let uid = AudioInputSelection.deviceUID(from: rawValue) {
            return eligible.first(where: { $0.id == uid })
        }
        return eligible.first(where: { $0.audioObjectID == defaultID })
    }

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var byteCount: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &byteCount
        ) == noErr else { return [] }

        var devices = Array(repeating: AudioDeviceID(0), count: Int(byteCount) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &byteCount, &devices
        ) == noErr else { return [] }
        return devices
    }

    private static func makeInputDevice(_ id: AudioDeviceID) -> AudioInputDevice? {
        guard inputChannelCount(id) > 0,
              let uid = stringProperty(id, selector: kAudioDevicePropertyDeviceUID),
              let name = stringProperty(id, selector: kAudioObjectPropertyName) else { return nil }
        let transportType = uint32Property(id, selector: kAudioDevicePropertyTransportType)
        let isHidden = uint32Property(id, selector: kAudioDevicePropertyIsHidden) != 0
        guard !isHidden,
              transportType != kAudioDeviceTransportTypeAutoAggregate,
              !uid.hasPrefix("CADefaultDeviceAggregate-") else { return nil }

        return AudioInputDevice(
            id: uid,
            name: name,
            audioObjectID: id,
            isBuiltIn: transportType == kAudioDeviceTransportTypeBuiltIn,
            isAlive: uint32Property(id, selector: kAudioDevicePropertyDeviceIsAlive) != 0
        )
    }

    private static func inputChannelCount(_ id: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var byteCount: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &byteCount) == noErr,
              byteCount > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(byteCount),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &byteCount, raw) == noErr else { return 0 }
        let buffers = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func defaultInputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = AudioDeviceID(0)
        var byteCount = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &byteCount, &id
        ) == noErr else { return nil }
        return id
    }

    private static func stringProperty(_ id: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var byteCount = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &byteCount, &value) == noErr,
              let value else { return nil }
        return value.takeUnretainedValue() as String
    }

    private static func uint32Property(_ id: AudioDeviceID, selector: AudioObjectPropertySelector) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var byteCount = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &byteCount, &value) == noErr else { return 0 }
        return value
    }
}
