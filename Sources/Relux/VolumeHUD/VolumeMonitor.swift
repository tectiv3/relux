import AudioToolbox
import CoreAudio
import os

struct VolumeSnapshot: Sendable, Equatable {
    let value: Float
    let isMuted: Bool
}

/// Observes the default output device's main volume and mute state through CoreAudio
/// property listeners. Emits snapshots on the main actor. Devices without a usable main
/// volume are skipped silently (no listeners, no snapshots).
@MainActor
final class VolumeMonitor {
    private let log = Logger(subsystem: "com.relux.app", category: "volumehud")
    private let onSnapshot: @MainActor (VolumeSnapshot) -> Void

    private var deviceID = AudioObjectID(kAudioObjectUnknown)
    private var isRunning = false

    private var volumeListener: AudioObjectPropertyListenerBlock?
    private var muteListener: AudioObjectPropertyListenerBlock?
    private var deviceListener: AudioObjectPropertyListenerBlock?

    init(onSnapshot: @escaping @MainActor (VolumeSnapshot) -> Void) {
        self.onSnapshot = onSnapshot
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        registerDeviceListener()
        attachToDefaultOutputDevice()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        removeDeviceListeners()
        removeDeviceListener()
        deviceID = AudioObjectID(kAudioObjectUnknown)
    }

    // MARK: - Default output device

    private func registerDeviceListener() {
        var address = defaultDeviceAddress()
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated {
                self?.defaultOutputDeviceChanged()
            }
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block
        )
        if status == noErr {
            deviceListener = block
        } else {
            log.error("Failed to register default-output-device listener (status \(status))")
        }
    }

    private func removeDeviceListener() {
        guard let block = deviceListener else { return }
        var address = defaultDeviceAddress()
        let status = AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block
        )
        if status != noErr {
            log.error("Failed to remove default-output-device listener (status \(status))")
        }
        deviceListener = nil
    }

    private func defaultOutputDeviceChanged() {
        log.info("Default output device changed; re-registering listeners")
        removeDeviceListeners()
        attachToDefaultOutputDevice()
    }

    private func attachToDefaultOutputDevice() {
        var address = defaultDeviceAddress()
        var resolved = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &resolved
        )
        guard status == noErr, resolved != AudioObjectID(kAudioObjectUnknown) else {
            log.error("No default output device available (status \(status))")
            return
        }
        deviceID = resolved
        registerDeviceListeners(for: resolved)
    }

    // MARK: - Device listeners

    private func registerDeviceListeners(for device: AudioObjectID) {
        guard volumeIsUsable(on: device) else {
            log.info("Default output device \(device) lacks a usable main volume; HUD listeners skipped")
            return
        }
        registerVolumeListener(on: device)
        if muteIsPresent(on: device) {
            registerMuteListener(on: device)
        }
    }

    private func registerVolumeListener(on device: AudioObjectID) {
        var address = volumeAddress()
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated {
                self?.emitSnapshot()
            }
        }
        let status = AudioObjectAddPropertyListenerBlock(device, &address, DispatchQueue.main, block)
        if status == noErr {
            volumeListener = block
        } else {
            log.error("Failed to register volume listener on device \(device) (status \(status))")
        }
    }

    private func registerMuteListener(on device: AudioObjectID) {
        var address = muteAddress()
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated {
                self?.emitSnapshot()
            }
        }
        let status = AudioObjectAddPropertyListenerBlock(device, &address, DispatchQueue.main, block)
        if status == noErr {
            muteListener = block
        } else {
            log.error("Failed to register mute listener on device \(device) (status \(status))")
        }
    }

    private func removeDeviceListeners() {
        if let block = volumeListener {
            var address = volumeAddress()
            let status = AudioObjectRemovePropertyListenerBlock(deviceID, &address, DispatchQueue.main, block)
            if status != noErr {
                log.error("Failed to remove volume listener (status \(status))")
            }
        }
        if let block = muteListener {
            var address = muteAddress()
            let status = AudioObjectRemovePropertyListenerBlock(deviceID, &address, DispatchQueue.main, block)
            if status != noErr {
                log.error("Failed to remove mute listener (status \(status))")
            }
        }
        volumeListener = nil
        muteListener = nil
    }

    // MARK: - Capability checks

    private func volumeIsUsable(on device: AudioObjectID) -> Bool {
        var address = volumeAddress()
        guard AudioObjectHasProperty(device, &address) else { return false }
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr
    }

    private func muteIsPresent(on device: AudioObjectID) -> Bool {
        var address = muteAddress()
        return AudioObjectHasProperty(device, &address)
    }

    // MARK: - Reading state

    private func emitSnapshot() {
        let device = deviceID
        guard device != AudioObjectID(kAudioObjectUnknown) else { return }

        var volume: Float32 = 0
        var volumeSize = UInt32(MemoryLayout<Float32>.size)
        var volumeAddr = volumeAddress()
        guard AudioObjectGetPropertyData(device, &volumeAddr, 0, nil, &volumeSize, &volume) == noErr else {
            log.error("Failed to read main volume on device \(device)")
            return
        }

        var isMuted = false
        var muteAddr = muteAddress()
        if AudioObjectHasProperty(device, &muteAddr) {
            var mute: UInt32 = 0
            var muteSize = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(device, &muteAddr, 0, nil, &muteSize, &mute) == noErr {
                isMuted = mute != 0
            } else {
                log.error("Failed to read mute state on device \(device); treating as unmuted")
            }
        }

        onSnapshot(VolumeSnapshot(value: volume, isMuted: isMuted))
    }

    // MARK: - Addresses

    private func defaultDeviceAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private func volumeAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private func muteAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
    }
}
