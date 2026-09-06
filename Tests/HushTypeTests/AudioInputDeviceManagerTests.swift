import CoreAudio
import XCTest
@testable import HushType

final class AudioInputDeviceManagerTests: XCTestCase {
    private let remote = AudioInputDevice(
        id: "remote",
        name: "iPhone Microphone",
        audioObjectID: 1,
        isBuiltIn: false,
        isAlive: true,
        transportType: kAudioDeviceTransportTypeContinuityCaptureWireless
    )
    private let builtIn = AudioInputDevice(
        id: "built-in",
        name: "MacBook Microphone",
        audioObjectID: 2,
        isBuiltIn: true,
        isAlive: true,
        transportType: kAudioDeviceTransportTypeBuiltIn
    )
    private let virtual = AudioInputDevice(
        id: "virtual",
        name: "Virtual Audio Device",
        audioObjectID: 3,
        isBuiltIn: false,
        isAlive: true,
        transportType: kAudioDeviceTransportTypeVirtual
    )

    func testAutomaticSelectionPrefersSystemDefault() {
        let result = AudioInputDeviceManager.resolvedDevice(
            rawValue: AudioInputSelection.automatic,
            devices: [builtIn, remote],
            defaultID: remote.audioObjectID
        )
        XCTAssertEqual(result, remote)
    }

    func testAutomaticFallbackExcludesDisconnectedDeviceAndPrefersBuiltIn() {
        let result = AudioInputDeviceManager.resolvedDevice(
            rawValue: AudioInputSelection.automatic,
            devices: [remote, virtual, builtIn],
            defaultID: remote.audioObjectID,
            excludingUID: remote.id
        )
        XCTAssertEqual(result, builtIn)
    }

    func testAutomaticFallbackOccursOnlyOnce() {
        XCTAssertTrue(AudioCaptureRecoveryPolicy.shouldAttemptAutomaticFallback(
            selection: AudioInputSelection.automatic,
            alreadyAttempted: false
        ))
        XCTAssertFalse(AudioCaptureRecoveryPolicy.shouldAttemptAutomaticFallback(
            selection: AudioInputSelection.automatic,
            alreadyAttempted: true
        ))
        XCTAssertFalse(AudioCaptureRecoveryPolicy.shouldAttemptAutomaticFallback(
            selection: AudioInputSelection.followSystem,
            alreadyAttempted: false
        ))
    }

    func testExplicitDeviceDoesNotSilentlyFallBack() {
        XCTAssertNil(AudioInputDeviceManager.resolvedDevice(
            rawValue: AudioInputSelection.device("missing"),
            devices: [builtIn, remote],
            defaultID: builtIn.audioObjectID
        ))
    }

    func testAvailabilityRequiresSameListedAndAliveDevice() {
        XCTAssertTrue(AudioInputDeviceManager.availabilitySnapshotIsUsable(
            audioObjectID: remote.audioObjectID,
            expectedUID: remote.id,
            listedDeviceIDs: [remote.audioObjectID, builtIn.audioObjectID],
            observedUID: remote.id,
            isAlive: true
        ))
        XCTAssertFalse(AudioInputDeviceManager.availabilitySnapshotIsUsable(
            audioObjectID: remote.audioObjectID,
            expectedUID: remote.id,
            listedDeviceIDs: [builtIn.audioObjectID],
            observedUID: remote.id,
            isAlive: true
        ))
        XCTAssertFalse(AudioInputDeviceManager.availabilitySnapshotIsUsable(
            audioObjectID: remote.audioObjectID,
            expectedUID: remote.id,
            listedDeviceIDs: [remote.audioObjectID],
            observedUID: remote.id,
            isAlive: false
        ))
    }

    func testBufferStallRequiresStartedMonitoringAndElapsedThreshold() {
        XCTAssertFalse(AudioCaptureHealthPolicy.isBufferStreamStalled(
            monitoringEnabled: false,
            secondsSinceLastBuffer: 30
        ))
        XCTAssertFalse(AudioCaptureHealthPolicy.isBufferStreamStalled(
            monitoringEnabled: true,
            secondsSinceLastBuffer: nil
        ))
        XCTAssertFalse(AudioCaptureHealthPolicy.isBufferStreamStalled(
            monitoringEnabled: true,
            secondsSinceLastBuffer: AudioCaptureHealthPolicy.bufferStallThreshold - 0.01
        ))
        XCTAssertTrue(AudioCaptureHealthPolicy.isBufferStreamStalled(
            monitoringEnabled: true,
            secondsSinceLastBuffer: AudioCaptureHealthPolicy.bufferStallThreshold
        ))
    }

    func testBluetoothDependentInputTransportsAreClassifiedWithoutUsingDeviceNames() {
        XCTAssertTrue(AudioInputDeviceManager.requiresPoweredBluetoothController(
            transportType: kAudioDeviceTransportTypeBluetooth
        ))
        XCTAssertTrue(AudioInputDeviceManager.requiresPoweredBluetoothController(
            transportType: kAudioDeviceTransportTypeBluetoothLE
        ))
        XCTAssertTrue(AudioInputDeviceManager.requiresPoweredBluetoothController(
            transportType: kAudioDeviceTransportTypeContinuityCaptureWireless
        ))
        XCTAssertFalse(AudioInputDeviceManager.requiresPoweredBluetoothController(
            transportType: kAudioDeviceTransportTypeContinuityCaptureWired
        ))
        XCTAssertFalse(AudioInputDeviceManager.requiresPoweredBluetoothController(
            transportType: kAudioDeviceTransportTypeBuiltIn
        ))
    }

    func testBluetoothTransportFailsOnlyWhenControllerIsKnownToBeOff() {
        XCTAssertTrue(AudioCaptureHealthPolicy.isBluetoothTransportUnavailable(
            requiresPoweredController: true,
            controllerIsPoweredOn: false
        ))
        XCTAssertFalse(AudioCaptureHealthPolicy.isBluetoothTransportUnavailable(
            requiresPoweredController: true,
            controllerIsPoweredOn: true
        ))
        XCTAssertFalse(AudioCaptureHealthPolicy.isBluetoothTransportUnavailable(
            requiresPoweredController: true,
            controllerIsPoweredOn: nil
        ))
        XCTAssertFalse(AudioCaptureHealthPolicy.isBluetoothTransportUnavailable(
            requiresPoweredController: false,
            controllerIsPoweredOn: false
        ))
    }

    func testBluetoothPowerProbeDoesNotRequireCreatingABluetoothController() {
        _ = AudioInputDeviceManager.bluetoothControllerIsPoweredOn()
    }
}
