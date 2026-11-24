// Adapted from Fader (https://github.com/pantafive/fader).
// Copyright (c) 2026 pantafive. MIT License — see THIRD_PARTY_NOTICES.md.

import CoreAudio
import Foundation

/// Shared names for the per-app volume plumbing.
enum PerAppAudio {
    /// Every tap and aggregate CbarDuo creates carries this prefix, so its own
    /// plumbing never shows up as a user-selectable device.
    static let plumbingNamePrefix = "CbarDuo"
}

/// Thin throwing wrappers over the Core Audio HAL property API.
enum HALError: Error {
    case osStatus(OSStatus, AudioObjectPropertySelector)
    /// A non-property HAL call (tap, aggregate, IO-proc setup) failed.
    case operation(OSStatus, String)
}

extension HALError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case let .osStatus(status, selector):
            "HAL property \(selector) failed: OSStatus \(status)"
        case let .operation(status, what):
            "Failed to \(what): OSStatus \(status)"
        }
    }

    /// Core Audio uses a dedicated status for denied capture access.
    var isPermissionDenied: Bool {
        switch self {
        case let .osStatus(status, _), let .operation(status, _):
            status == kAudioDevicePermissionsError
        }
    }
}

/// Converts an OSStatus into a thrown HALError with context.
func checked(_ status: OSStatus, _ what: @autoclosure () -> String) throws {
    guard status == noErr else {
        throw HALError.operation(status, what())
    }
}

extension AudioObjectID {
    static let system = AudioObjectID(kAudioObjectSystemObject)
    static let unknown = AudioObjectID(kAudioObjectUnknown)

    var isValid: Bool { self != Self.unknown }

    fileprivate static func address(_ selector: AudioObjectPropertySelector,
                                    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal)
        -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    /// Reads a fixed-size, trivial C-layout property value.
    func read<T>(_ selector: AudioObjectPropertySelector,
                 scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                 into value: inout T) throws {
        var address = Self.address(selector, scope: scope)
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &value) { ptr in
            AudioObjectGetPropertyData(self, &address, 0, nil, &size, ptr)
        }
        guard status == noErr else { throw HALError.osStatus(status, selector) }
    }

    /// Reads a variable-length array property.
    func readArray<T>(_ selector: AudioObjectPropertySelector,
                      scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                      of type: T.Type) throws -> [T] {
        var address = Self.address(selector, scope: scope)
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(self, &address, 0, nil, &size)
        guard status == noErr else { throw HALError.osStatus(status, selector) }
        let count = Int(size) / MemoryLayout<T>.stride
        guard count > 0 else { return [] }
        var values = [T](unsafeUninitializedCapacity: count) { _, initialized in initialized = count }
        status = values.withUnsafeMutableBufferPointer { buffer in
            AudioObjectGetPropertyData(self, &address, 0, nil, &size, buffer.baseAddress!)
        }
        guard status == noErr else { throw HALError.osStatus(status, selector) }
        return values
    }

    func readString(_ selector: AudioObjectPropertySelector) throws -> String {
        var value: CFString = "" as CFString
        try read(selector, into: &value)
        return value as String
    }

    func write<T>(_ selector: AudioObjectPropertySelector,
                  scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                  value: T) throws {
        var address = Self.address(selector, scope: scope)
        let status = withUnsafePointer(to: value) { ptr in
            AudioObjectSetPropertyData(self, &address, 0, nil, UInt32(MemoryLayout<T>.size), ptr)
        }
        guard status == noErr else { throw HALError.osStatus(status, selector) }
    }

    /// Writes an Objective-C/Core Foundation object property (HAL expects the
    /// address of the object reference).
    func writeObjectReference(_ selector: AudioObjectPropertySelector, value: AnyObject) throws {
        var address = Self.address(selector)
        var reference = Unmanaged.passUnretained(value).toOpaque()
        let status = withUnsafePointer(to: &reference) { pointer in
            AudioObjectSetPropertyData(
                self, &address, 0, nil, UInt32(MemoryLayout<UnsafeMutableRawPointer>.size), pointer
            )
        }
        guard status == noErr else { throw HALError.osStatus(status, selector) }
    }

    func isSettable(_ selector: AudioObjectPropertySelector,
                    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> Bool {
        var address = Self.address(selector, scope: scope)
        var settable = DarwinBoolean(false)
        guard AudioObjectIsPropertySettable(self, &address, &settable) == noErr else { return false }
        return settable.boolValue
    }

    func listen(_ selector: AudioObjectPropertySelector,
                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                onChange: @escaping @Sendable () -> Void) -> HALListener {
        HALListener(objectID: self, address: Self.address(selector, scope: scope), onChange: onChange)
    }

    // MARK: Typed conveniences

    static func readDefaultOutputDevice() throws -> AudioDeviceID {
        var device = AudioDeviceID.unknown
        try AudioObjectID.system.read(kAudioHardwarePropertyDefaultOutputDevice, into: &device)
        return device
    }

    static func readProcessList() throws -> [AudioObjectID] {
        try AudioObjectID.system.readArray(kAudioHardwarePropertyProcessObjectList, of: AudioObjectID.self)
    }

    func readProcessPID() throws -> pid_t {
        var pid: pid_t = -1
        try read(kAudioProcessPropertyPID, into: &pid)
        return pid
    }

    func readProcessIsRunningOutput() -> Bool {
        var value: UInt32 = 0
        try? read(kAudioProcessPropertyIsRunningOutput, into: &value)
        return value != 0
    }

    func readProcessIsRunningInput() -> Bool {
        var value: UInt32 = 0
        try? read(kAudioProcessPropertyIsRunningInput, into: &value)
        return value != 0
    }

    func readDeviceUID() throws -> String {
        try readString(kAudioDevicePropertyDeviceUID)
    }
}

/// RAII wrapper for a HAL property listener block dispatched to the main queue.
final class HALListener: @unchecked Sendable {
    private let objectID: AudioObjectID
    private var address: AudioObjectPropertyAddress
    private let block: AudioObjectPropertyListenerBlock

    init(objectID: AudioObjectID, address: AudioObjectPropertyAddress, onChange: @escaping @Sendable () -> Void) {
        self.objectID = objectID
        self.address = address
        block = { _, _ in onChange() }
        AudioObjectAddPropertyListenerBlock(objectID, &self.address, .main, block)
    }

    deinit {
        AudioObjectRemovePropertyListenerBlock(objectID, &address, .main, block)
    }
}

/// An output device an app can be routed to.
struct TapOutputDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let transport: UInt32

    var isBluetooth: Bool {
        transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    /// User-selectable output devices, CbarDuo's own plumbing left out.
    static func currentOutputs() -> [TapOutputDevice] {
        let ids = (try? AudioObjectID.system.readArray(kAudioHardwarePropertyDevices, of: AudioDeviceID.self)) ?? []
        return ids.compactMap { id -> TapOutputDevice? in
            guard let uid = try? id.readDeviceUID(),
                  let name = try? id.readString(kAudioObjectPropertyName),
                  hasOutputStreams(id)
            else { return nil }
            var transport: UInt32 = 0
            try? id.read(kAudioDevicePropertyTransportType, into: &transport)
            if transport == kAudioDeviceTransportTypeAggregate, name.hasPrefix(PerAppAudio.plumbingNamePrefix) {
                return nil
            }
            var hidden: UInt32 = 0
            try? id.read(kAudioDevicePropertyIsHidden, into: &hidden)
            guard hidden == 0 else { return nil }
            return TapOutputDevice(id: id, uid: uid, name: name, transport: transport)
        }
    }

    private static func hasOutputStreams(_ id: AudioDeviceID) -> Bool {
        let streams = (try? id.readArray(kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeOutput,
                                         of: AudioStreamID.self)) ?? []
        return !streams.isEmpty
    }
}
