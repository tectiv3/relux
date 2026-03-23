# macOS IOKit HID Keyboard Interception - Deep Research

## Executive Summary

Intercepting macOS hardware function keys (F3/Mission Control, F4/Launchpad, etc.) at the system level requires understanding three distinct architectural layers:

1. **IOHIDFamily** (kernel) — lowest level HID device access
2. **IOHIDManager** (userland C API) — HID device enumeration and monitoring
3. **CGEventTap** (userland Graphics API) — system-wide event interception

**Key Finding**: IOHIDManager can monitor keyboard input but **cannot suppress/block events**. Only CGEventTap with Accessibility permission can block events. Modern system keys (media, Mission Control) are handled differently than regular keyboard events.

---

## 1. IOKit HID Keyboard Interception Architecture

### 1.1 Overview: IOHIDFamily to Application

```
Physical Keyboard
        ↓
USB/Input Device
        ↓
IOHIDFamily (kernel)
        ↓
IOHIDManager (userland C API)
        ↓
Application via IOHIDDeviceRegisterInputValueCallback
```

The IOHIDFamily kernel extension provides an abstract interface for HID devices (keyboards, mice, trackpads, etc.). It abstracts away USB details and presents a unified HID interface.

**Source**: [Dev:IOHIDFamily - The Apple Wiki](https://theapplewiki.com/wiki/Dev:IOHIDFamily)

### 1.2 IOHIDManager API Fundamentals

IOHIDManager is a Core Foundation-style API (not Objective-C) that provides:

- **Device enumeration** — discover attached HID devices
- **Matching criteria** — filter devices by usage page, usage ID, vendor ID, etc.
- **Input value callbacks** — register C function pointers to receive keyboard events
- **Device property access** — manufacturer, product ID, location ID, capabilities

**Key Limitation**: IOHIDManager callbacks only **observe** input values. They cannot suppress or modify events before they reach the system.

**Source**: [IOHIDManager.h - Apple Developer Documentation](https://developer.apple.com/documentation/iokit/iohidmanager_h)

### 1.3 Core IOHIDManager Functions

| Function | Purpose |
|----------|---------|
| `IOHIDManagerCreate()` | Create new manager reference |
| `IOHIDManagerOpen()` | Open manager for device enumeration |
| `IOHIDManagerSetDeviceMatching()` | Set single matching dictionary (usage page/ID) |
| `IOHIDManagerSetDeviceMatchingMultiple()` | Set array of matching dictionaries |
| `IOHIDManagerCopyDevices()` | Get CFSetRef of matched IOHIDDeviceRef |
| `IOHIDManagerRegisterInputValueCallback()` | Register callback for input events |
| `IOHIDManagerScheduleWithRunLoop()` | Add manager to run loop for async callbacks |

**Source**: [Technical Note TN2187: New HID Manager APIs for Mac OS X version 10.5](https://developer.apple.com/library/archive/technotes/tn2187/_index.html)

### 1.4 Matching Dictionary Setup for Keyboards

To enumerate keyboard devices, create matching dictionaries with:

```c
kIOHIDDeviceUsagePageKey    // HID Usage Page (e.g., 0x07 for Keyboard)
kIOHIDDeviceUsageKey         // HID Usage ID (e.g., 0x06 for Keyboard)
```

For keyboard/keypad devices:
- **Usage Page**: `0x07` (Keyboard/Keypad)
- **Usage ID**: `0x06` (Keyboard Device)

For all devices (NULL matching):
```c
IOHIDManagerSetDeviceMatching(manager, NULL);
```

**Source**: [Accessing a HID Device - Apple Developer Documentation](https://developer.apple.com/library/archive/documentation/DeviceDrivers/Conceptual/HID/new_api_10_5/tn2187.html)

---

## 2. Special Function Keys (F3/Mission Control, F4/Launchpad)

### 2.1 HID Usage Pages for Special Keys

Not all keyboard keys use the Keyboard Page (0x07). Special function keys use **Apple's vendor-defined usage page**:

| Key | Page | Usage | Alternative Representation |
|-----|------|-------|---------------------------|
| F3 (Mission Control) | 0xFF01 | 0x0010 | `0xff010010` (32-bit) or `0xff0100000010` (64-bit) |
| F4 (Launchpad) | 0xFF01 | 0x0002 | `0xff010002` |
| Standard F1-F12 | 0x07 | 0x3A-0x45 | Keyboard Page codes |

**Apple Vendor-Defined Page**: `0xFF01` — contains Apple-specific functions like Expose, Launchpad, and other macOS-specific features.

**Source**: [macOS function key remapping with hidutil - nanoANT](https://www.nanoant.com/mac/macos-function-key-remapping-with-hidutil)

### 2.2 Understanding HID Code Format

A complete HID function key code is a 32-bit (or 64-bit padded) value:

```
0xFF010010 = 0xFF01 (page) | 0x0010 (usage)
```

When padded to 64-bit for use with `hidutil`:
```
0xFF0100000010
```

This same code `0xFF010010` is what Karabiner-Elements and `hidutil` use to identify Mission Control on F3.

**Keyboard Page (0x07) Standard Codes**:
- `0x3A` = F1
- `0x3B` = F2
- `0x3C` = F3 (standard, not vendor-specific)
- `0x3D` = F4 (standard, not vendor-specific)
- ... up to `0x45` = F12

**Source**: [Guide on how to remap Keyboard keys on macOS - GitHub Gist](https://gist.github.com/paultheman/808be117d447c490a29d6405975d41bd)

### 2.3 Why These Keys Are Special

On modern Apple keyboards, F3 and F4 are **illumination keys** (brightness control). macOS system software intercepts them before application-level callbacks fire and maps them to Mission Control and Launchpad.

- **Built-in behavior**: engraved symbols (Mission Control on F3, Launchpad on F4)
- **System priority**: intercepted at IOHIDFamily level
- **Hard to remap**: Karabiner-Elements requires **exclusive grab** of the keyboard to prevent macOS from handling them first

---

## 3. IOHIDValue and IOHIDElement: Event Parsing

### 3.1 IOHIDValue Structure

When an input callback fires, you receive an `IOHIDValueRef` containing:

```
IOHIDValue
├─ IOHIDElementRef (points to element definition)
│  ├─ usagePage (0x07 for keyboard, 0xFF01 for vendor, 0x0C for consumer)
│  ├─ usage (0x06 for keyboard device, or specific key codes)
│  ├─ reportID (which report contains this element)
│  ├─ type (input, output, feature)
│  └─ ...
├─ integerValue (pressed=1, released=0)
├─ timeStamp (IOKit nanosecond timestamp)
└─ reportID (from HID report)
```

### 3.2 Parsing Keys from IOHIDValue

```c
IOHIDElementRef element = IOHIDValueGetElement(value);
uint32_t usagePage = IOHIDElementGetUsagePage(element);
uint32_t usage = IOHIDElementGetUsage(element);
int64_t intValue = IOHIDValueGetIntegerValue(value);

// For F3 (Mission Control):
// usagePage = 0xFF01
// usage = 0x0010
// intValue = 1 (pressed) or 0 (released)
```

### 3.3 Keyboard Keypad Page (0x07) Usage Codes

```
0x01-0x04 = Modifiers (Left Control, Left Shift, Left Alt, Left GUI)
0x05      = Error Rollover
0x06      = POST Fail
0x07      = Error Undefined
0x08-0x91 = Keyboard Keys (A-Z, 0-9, Enter, Escape, etc.)
0x3A      = F1
0x3B      = F2
0x3C      = F3 (standard F3 code, but Apple maps to brightness)
0x3D      = F4 (standard F4 code, but Apple maps to brightness)
```

**Important**: The standard keyboard F3/F4 codes (0x3C/0x3D) may not be what arrives. Apple's firmware may send vendor-page codes (0xFF010010) instead.

**Source**: [Keyboard/Keypad Page (0x07) - GitHub Gist](https://gist.github.com/mildsunrise/4e231346e2078f440969cdefb6d4caa3)

---

## 4. Swift/Objective-C Code Implementation

### 4.1 C Function Pointer Callback Challenge

IOHIDManager uses **C function pointers**, not closures. From Swift, this is problematic:

- Swift closures cannot be converted to C function pointers if they capture state
- The compiler only allows **nonisolated, non-capturing** closures to bridge to C function pointers
- Solution: Use `Unmanaged<T>` and void pointers to pass context

### 4.2 Basic Objective-C Pattern

```objc
// Callback function (must be global or static, no captures)
static void IOHIDValueCallback(void *context, IOReturn result,
                               void *sender, IOHIDValueRef value) {
    MyManager *manager = (__bridge MyManager *)context;

    IOHIDElementRef element = IOHIDValueGetElement(value);
    uint32_t usagePage = IOHIDElementGetUsagePage(element);
    uint32_t usage = IOHIDElementGetUsage(element);
    CFIndex intValue = IOHIDValueGetIntegerValue(value);

    // Handle event
    if (usagePage == 0xFF01 && usage == 0x0010) {
        NSLog(@"Mission Control key pressed");
    }
}

// Setup in manager
- (void)startMonitoring {
    IOHIDManagerRef manager = IOHIDManagerCreate(kCFAllocatorDefault,
                                                 kIOHIDOptionsTypeNone);

    CFDictionaryRef matching = CFDictionaryCreate(...);
    IOHIDManagerSetDeviceMatching(manager, matching);

    IOReturn ret = IOHIDManagerOpen(manager, kIOHIDOptionsTypeNone);

    IOHIDManagerRegisterInputValueCallback(
        manager, IOHIDValueCallback, (__bridge void *)self);

    IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(),
                                     kCFRunLoopDefaultMode);
}
```

### 4.3 Swift Wrapper Pattern Using Unmanaged

```swift
import IOKit
import Foundation

class KeyboardMonitor {
    private var manager: IOHIDManagerRef?
    private var devices = Set<IOHIDDeviceRef>()

    func startMonitoring() {
        // Create manager
        guard let mgr = IOHIDManagerCreate(kCFAllocatorDefault,
                                           kIOHIDOptionsTypeNone) else {
            return
        }
        self.manager = mgr

        // Set matching for keyboard devices
        let matching = [
            kIOHIDDeviceUsagePageKey: NSNumber(value: 0x07),
            kIOHIDDeviceUsageKey: NSNumber(value: 0x06)
        ] as CFDictionary

        IOHIDManagerSetDeviceMatching(mgr, matching)

        // Open manager
        let ret = IOHIDManagerOpen(mgr, kIOHIDOptionsTypeNone)
        guard ret == kIOReturnSuccess else {
            return
        }

        // Register callback using Unmanaged
        let unmanaged = Unmanaged.passUnretained(self)
        IOHIDManagerRegisterInputValueCallback(
            mgr, keyboardCallback, unmanaged.toOpaque())

        // Schedule on run loop
        IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetMain(),
                                         kCFRunLoopDefaultMode)
    }
}

// Global callback function
private func keyboardCallback(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    value: IOHIDValueRef) {

    guard let context = context else { return }
    let monitor = Unmanaged<KeyboardMonitor>.fromOpaque(context).takeUnretainedValue()

    let element = IOHIDValueGetElement(value)
    let usagePage = IOHIDElementGetUsagePage(element)
    let usage = IOHIDElementGetUsage(element)
    let intValue = IOHIDValueGetIntegerValue(value)

    if usagePage == 0xFF01 && usage == 0x0010 {
        print("F3 Mission Control: \(intValue == 1 ? "pressed" : "released")")
    }
}
```

**Key Points**:
- Callback must be `@convention(c)` or a C function
- No capture of self or local variables allowed
- Use `Unmanaged<Self>.passUnretained(self)` to encode self in void pointer
- Retrieve with `Unmanaged<Self>.fromOpaque(context).takeUnretainedValue()`

**Source**: [C Callbacks in Swift - Ole Begemann](https://oleb.net/blog/2015/06/c-callbacks-in-swift/)

### 4.4 Key API Details for Swift

These are the main IOKit functions you'll use:

```swift
// From IOKit/hid/IOHIDManager.h
IOHIDManagerCreate(allocator: CFAllocator?, options: IOOptionBits) -> IOHIDManagerRef?
IOHIDManagerOpen(manager: IOHIDManagerRef, options: IOOptionBits) -> IOReturn
IOHIDManagerSetDeviceMatching(manager: IOHIDManagerRef, matching: CFDictionary?)
IOHIDManagerRegisterInputValueCallback(
    manager: IOHIDManagerRef,
    callback: IOHIDValueCallback,
    context: UnsafeMutableRawPointer?)
IOHIDManagerScheduleWithRunLoop(
    manager: IOHIDManagerRef,
    runLoop: CFRunLoop,
    mode: CFRunLoopMode)

// From IOKit/hid/IOHIDElement.h
IOHIDElementGetUsagePage(element: IOHIDElementRef) -> UInt32
IOHIDElementGetUsage(element: IOHIDElementRef) -> UInt32
IOHIDElementGetType(element: IOHIDElementRef) -> IOHIDElementType

// From IOKit/hid/IOHIDValue.h
IOHIDValueGetElement(value: IOHIDValueRef) -> IOHIDElementRef
IOHIDValueGetIntegerValue(value: IOHIDValueRef) -> CFIndex
```

---

## 5. CGEventTap: System-Wide Event Interception

### 5.1 CGEventTap vs IOHIDManager

| Feature | IOHIDManager | CGEventTap |
|---------|-------------|-----------|
| Level | HID hardware layer | Graphics/event system layer |
| Can observe | ✓ Yes | ✓ Yes |
| Can suppress/block | ✗ No | ✓ Yes (with Accessibility) |
| System keys (F3, F4) | May not see (intercepted first) | ✓ Can see as NX_SYSDEFINED |
| Permission | Input Monitoring | Accessibility or Input Monitoring |
| Thread safety | Must schedule on run loop | Callback on private thread |

### 5.2 CGEventTap with System-Defined Events

System-defined keys (media, brightness, Mission Control) arrive as `NX_SYSDEFINED` event type:

```swift
let tap = CGEventTapCreate(
    tap: .cghidEventTap,
    place: .headInsertEventTap,
    options: .default,  // or .listenOnly
    eventsOfInterest: UInt32(NSEventMask.systemDefined.rawValue),
    callback: eventTapCallback,
    userInfo: nil)

// Callback receives system-defined events
// Contains NX_ key codes in the event data
```

**Event Type**: `kCGEventSystemDefined` (value 13)

### 5.3 NX_KEYTYPE Values for Special Keys

System-defined keys use `NX_KEYTYPE_` constants in the event data:

```c
#define NX_KEYTYPE_SOUND_UP     0
#define NX_KEYTYPE_SOUND_DOWN   1
#define NX_KEYTYPE_BRIGHTNESS_UP    2
#define NX_KEYTYPE_BRIGHTNESS_DOWN  3
#define NX_KEYTYPE_CAPS_LOCK    4
#define NX_KEYTYPE_HELP         5
#define NX_KEYTYPE_POWER        6
#define NX_KEYTYPE_MUTE         7
#define NX_KEYTYPE_NUM_LOCK     15
// ... more codes
```

**Note**: F3 (Mission Control) and F4 (Launchpad) are handled specially and may not appear as regular NX_KEYTYPE values.

### 5.4 Permission Requirements

```swift
import AppKit

// Option 1: DefaultTap (can filter/suppress events)
let tap = CGEventTapCreate(...)  // requires Accessibility permission
if tap == nil {
    // No Accessibility permission
}

// Option 2: ListenOnly (passive monitoring)
let tap = CGEventTapCreate(...,
    options: .listenOnly,
    ...)  // requires Input Monitoring permission

// Preflight check (before requesting permission)
if !CGPreflightListenEventAccess() {
    // Request permission
    CGRequestListenEventAccess()
}
```

**Important**:
- `.default` tap requires **Accessibility** permission (stronger)
- `.listenOnly` tap requires **Input Monitoring** permission (weaker, App Store compatible)
- `.listenOnly` cannot suppress events (informational only)

**Source**: [CGEvent Taps and Code Signing - Daniel's Journal](https://danielraffel.me/til/2026/02/19/cgevent-taps-and-code-signing-the-silent-disable-race/)

---

## 6. Permissions and Entitlements

### 6.1 Input Monitoring Permission

Required for IOHIDManager access:

**Privacy Key**: `Privacy_ListenEvent` (in TCC database)
**User Prompt**: "System Preferences > Security & Privacy > Input Monitoring"
**App Must Declare**: Usage description in Info.plist

```xml
<key>NSPrivacyTrackingDomains</key>
<array/>
<key>NSPrivacyAccessedAPITypes</key>
<array>
  <dict>
    <key>NSPrivacyAccessedAPIType</key>
    <string>NSPrivacyAccessedAPITypeListeningEvent</string>
  </dict>
</array>
```

**Triggered when**: Calling `IOHIDManagerOpen()` automatically triggers the privacy prompt.

**Enforcement**: If denied, `IOHIDManagerOpen()` succeeds, but no devices are enumerated and no callbacks fire.

### 6.2 Accessibility Permission

Required for CGEventTap with `.default` option:

**Privacy Key**: `kAXTrustedCheckOptionPrompt`
**User Prompt**: "System Preferences > Security & Privacy > Accessibility"

```swift
import ApplicationServices

if !AXIsProcessTrusted() {
    AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt: true] as CFDictionary)
}
```

### 6.3 Sandbox Entitlements

For sandboxed apps (Mac App Store):

| Entitlement | Purpose | IOKit HID |
|-------------|---------|----------|
| `com.apple.security.device.usb` | USB device access | May help HID access |
| `com.apple.security.device.hid` | HID device access | Undocumented, limited support |
| Neither | Default sandbox | HID access blocked |

**Finding**: Even with sandbox exceptions, IOHIDManager access is problematic. Most keyboard monitoring tools are **not sandboxed**.

**Source**: [macOS IOHIDManager Permission Issue - John's Blog](https://nachtimwald.com/2020/11/08/macos-iohidmanager-permission-issue/)

---

## 7. Alternative Approaches: Event Interception Strategies

### 7.1 Three Ways to Intercept Keyboard Events

| Method | Level | Can Suppress | Sees System Keys | Code Complexity |
|--------|-------|-------------|------------------|-----------------|
| IOHIDManager | HID hardware | No | Maybe (depends on Apple routing) | High (C API, callbacks) |
| CGEventTap | Graphics/events | Yes (with Accessibility) | Yes (as NX_SYSDEFINED) | Medium (CoreGraphics) |
| NSEvent.addGlobalMonitor | Cocoa | No | No | Low (Cocoa) |

**NSEvent Global Monitor** (NOT recommended for system keys):
```swift
NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
    // This WILL NOT see system-defined keys like F3
    // Only regular key presses in Cocoa windows
}
```

### 7.2 Karabiner-Elements Strategy

Karabiner-Elements avoids the "IOHIDManager can't suppress" limitation by:

1. **Exclusive HID grab** — Uses IOKit to claim exclusive access to keyboard hardware
2. **No user-space suppression** — Cannot suppress at user level anyway
3. **Virtual HID output** — Creates virtual keyboard via DriverKit
4. **Event transformation** — Reads HID input, transforms it in-process, sends to virtual device
5. **System sees virtual output** — macOS processes events from virtual device, not original

This is why Karabiner can remap even Mission Control and Launchpad keys — it intercepts before the system does.

**Source**: [GitHub - pqrs-org/Karabiner-Elements](https://github.com/pqrs-org/Karabiner-Elements)

### 7.3 Karabiner-DriverKit-VirtualHIDDevice Architecture

```
Physical Keyboard
        ↓
IOKit HID grab (exclusive)
        ↓
Karabiner-Core-Service (reads, modifies)
        ↓
Karabiner-DriverKit-VirtualHIDDevice (DriverKit kernel extension)
        ↓
Virtual HID device (recognized as physical hardware)
        ↓
macOS system (processes virtual output)
```

**Key Feature**: Virtual devices created with DriverKit are recognized as physical hardware by macOS, so system-level shortcuts work with transformed keys.

**Limitations**:
- Requires DriverKit signing (special Apple developer permissions)
- Runs with root privileges
- Cannot be sandboxed

**Source**: [Karabiner-DriverKit-VirtualHIDDevice - GitHub](https://github.com/pqrs-org/Karabiner-DriverKit-VirtualHIDDevice)

---

## 8. Event Suppression: The Core Limitation

### 8.1 Why IOHIDManager Cannot Suppress

IOHIDManager callbacks are **purely informational**:

- Reading from IOHIDValue does not provide event suppression mechanism
- Returning from callback does not suppress the event
- Even if you could suppress at HID level, it would bypass system-level handling

The IOKit architecture is **unidirectional**: hardware → driver → userland. There is no "veto" path back to the driver.

### 8.2 CGEventTap Suppression

CGEventTap supports suppression **only** with `.default` option (requires Accessibility):

```swift
func eventTapCallback(proxy: CGEventTapProxy,
                      type: CGEventType,
                      event: CGEvent,
                      refcon: UnsafeMutableRawPointer?) -> CGEvent? {

    if shouldSuppressEvent(event) {
        return nil  // Suppress: don't pass to next handler
    }
    return event  // Allow: pass through
}
```

Returning `nil` removes the event from the event stream entirely.

### 8.3 System Keys Cannot Be Suppressed Easily

Mission Control (F3) and Launchpad (F4) are **system-prioritized**:

1. Keyboard hardware sends HID data
2. IOHIDFamily processes it
3. System hooks claim it (before user-space IOHIDManager sees it)
4. By the time user-space code runs, the system action may already be triggered

Even with CGEventTap, suppressing these keys sometimes fails because they're intercepted at kernel/WindowServer level.

---

## 9. HID Matching and Device Filtering

### 9.1 Creating Matching Dictionaries

```swift
// Match keyboard devices (page 0x07, usage 0x06)
let keyboard: [String: Any] = [
    kIOHIDDeviceUsagePageKey as String: 0x07,
    kIOHIDDeviceUsageKey as String: 0x06
]

let matching = keyboard as CFDictionary
IOHIDManagerSetDeviceMatching(manager, matching)
```

### 9.2 Multiple Matching Criteria

```swift
// Match keyboard OR consumer devices
let criteria: [[String: Any]] = [
    [
        kIOHIDDeviceUsagePageKey as String: 0x07,
        kIOHIDDeviceUsageKey as String: 0x06
    ],
    [
        kIOHIDDeviceUsagePageKey as String: 0x0C,  // Consumer page
        kIOHIDDeviceUsageKey as String: 0x01       // Consumer control device
    ]
]

IOHIDManagerSetDeviceMatchingMultiple(manager, criteria as CFArray)
```

### 9.3 Filtering by Other Properties

```swift
let matching: [String: Any] = [
    kIOHIDDeviceUsagePageKey as String: 0x07,
    kIOHIDDeviceUsageKey as String: 0x06,
    kIOHIDVendorIDKey as String: 0x05AC,  // Apple Inc.
    kIOHIDProductIDKey as String: 0x0256, // Magic Keyboard
    kIOHIDLocationIDKey as String: 0x123  // USB port
]
```

**Available keys** (from IOHIDKeys.h):
- `kIOHIDDeviceUsagePageKey`
- `kIOHIDDeviceUsageKey`
- `kIOHIDVendorIDKey`
- `kIOHIDProductIDKey`
- `kIOHIDLocationIDKey`
- `kIOHIDSerialNumberKey`
- `kIOHIDManufacturerKey`
- `kIOHIDProductKey`
- And many more...

---

## 10. Open Source Projects & Examples

### 10.1 Karabiner-Elements

**Repository**: [pqrs-org/Karabiner-Elements](https://github.com/pqrs-org/Karabiner-Elements)

**Relevant Code**:
- IOKit HID grabbing and exclusive access
- Virtual HID device implementation (DriverKit-based)
- Event transformation pipeline
- System key remapping (F3, F4, media keys)

**Language**: Primarily C++ with Swift UI

**Key Insight**: Karabiner uses **exclusive HID grab** via IOKit to prevent the system from intercepting keys, then creates a virtual device to output transformed events.

### 10.2 hidapi (libusb)

**Repository**: [signal11/hidapi](https://github.com/signal11/hidapi)

**Relevant Code**:
- macOS IOHIDManager implementation (`mac/hid.c`)
- Device enumeration patterns
- IOHIDValue reading and parsing

**Language**: C with some platform-specific code

**Use Case**: Cross-platform HID device communication (not keyboard-specific)

### 10.3 Swift-Keylogger

**Repository**: [SkrewEverything/Swift-Keylogger](https://github.com/SkrewEverything/Swift-Keylogger)

**Relevant Code**:
- IOHIDManager setup in Swift
- Keyboard event parsing from IOHIDValue
- Context passing via Unmanaged

**Language**: Swift

**Warning**: This is a proof-of-concept keylogger. Use for educational purposes only.

---

## 11. Key Technical Insights

### 11.1 HID Usage Pages Summary

| Page | Name | Examples |
|------|------|----------|
| 0x01 | Generic Desktop | Pointer, Mouse, Joystick |
| 0x07 | Keyboard/Keypad | A-Z, F1-F12, Enter, Shift |
| 0x0C | Consumer | Play/Pause, Volume, Brightness |
| 0xFF01 | Apple Vendor | Mission Control, Launchpad, Expose |

### 11.2 Mission Control vs Standard F3

- **Standard F3**: Keyboard Page (0x07), Usage 0x3C
- **Mission Control on F3**: Apple Vendor Page (0xFF01), Usage 0x0010
- **What you receive**: Depends on Apple's keyboard firmware — may be either or both

### 11.3 Run Loop Scheduling

IOHIDManager callbacks require run loop integration:

```swift
IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(),
                                 kCFRunLoopDefaultMode)

// Without scheduling, callbacks never fire!
// Callbacks execute on the run loop's thread
```

### 11.4 Swift 6 Strict Concurrency Implications

Using IOHIDManager in Swift 6 strict mode is challenging:

- C function pointers cannot capture state (no `@Sendable` tricks help)
- `nonisolated(unsafe)` required for opaque pointers
- Unmanaged type-safety issues with `@MainActor` dispatch

**Solution**: Wrap IOHIDManager in Objective-C class, provide Swift interface.

### 11.5 Permission Timing

```swift
// This triggers permission prompt immediately:
let ret = IOHIDManagerOpen(manager, kIOHIDOptionsTypeNone)

// Not:
IOHIDManagerRegisterInputValueCallback(...)  // No prompt here

// Preflight check:
let access = IOHIDCheckAccess()  // Returns granted/denied/unknown
```

---

## 12. Practical Recommendations

### 12.1 For Hotkey Interception (Recommended)

Use **CGEventTap with `.listenOnly` option** (Input Monitoring only):

**Pros**:
- See system-defined keys including Mission Control
- No Accessibility permission required (more users can grant)
- Compatible with Mac App Store sandboxing (though requires entitlement)
- Simple Cocoa/CoreGraphics API
- Works reliably with system shortcuts

**Cons**:
- Cannot suppress events
- Cannot detect key releases reliably for some system keys
- May have higher latency than HID

### 12.2 For Exclusive Keyboard Control (Advanced)

Use **IOKit HID exclusive grab + DriverKit virtual device**:

**Pros**:
- Complete control over keyboard input
- Can remap any key including system shortcuts
- Highest priority (before system processing)

**Cons**:
- Requires DriverKit signing (special Apple permissions)
- Cannot be sandboxed
- Must run with elevated privileges
- Very complex implementation
- Only viable for established apps like Karabiner-Elements

### 12.3 For Relux Specifically

**Current Approach** (NSEvent global monitor) **will not see F3/F4**.

**Better Approach**:
1. Use CGEventTap with `.listenOnly` to detect system key presses
2. Parse NX_SYSDEFINED events for Mission Control (F3), Launchpad (F4), media keys
3. Respond with clipboard/translation actions without suppressing (system still opens Mission Control)

**Alternative**:
- User can disable Mission Control/Launchpad shortcuts in System Preferences
- Then use IOHIDManager or CGEventTap with `.default` to detect and suppress

---

## 13. References & Sources

**Apple Official Documentation**:
- [Technical Note TN2187: New HID Manager APIs](https://developer.apple.com/library/archive/technotes/tn2187/_index.html)
- [IOHIDManager.h Reference](https://developer.apple.com/documentation/iokit/iohidmanager_h)
- [IOHIDElement.h Reference](https://developer.apple.com/documentation/iokit/iohidelement_h)
- [CGEventTap Reference](https://developer.apple.com/documentation/coregraphics/cgeventtapcallback)
- [HIDDriverKit Documentation](https://developer.apple.com/documentation/hiddriverkit)

**Comprehensive Guides**:
- [The Evil Bit Blog: macOS Keylogging through HID](http://theevilbit.blogspot.com/2019/02/macos-keylogging-through-hid-device.html)
- [macOS Keyboard Event Interception - Three Ways](https://www.logcg.com/en/archives/2902.html)
- [macOS IOHIDManager Permission Issue](https://nachtimwald.com/2020/11/08/macos-iohidmanager-permission-issue/)

**Keyboard Remapping**:
- [macOS Function Key Remapping with hidutil](https://www.nanoant.com/mac/macos-function-key-remapping-with-hidutil)
- [Technical Note TN2450: Remapping Keys in macOS 10.12 Sierra](https://developer.apple.com/library/archive/technotes/tn2450/_index.html)

**Open Source**:
- [Karabiner-Elements - GitHub](https://github.com/pqrs-org/Karabiner-Elements)
- [Karabiner-DriverKit-VirtualHIDDevice - GitHub](https://github.com/pqrs-org/Karabiner-DriverKit-VirtualHIDDevice)
- [hidapi - GitHub](https://github.com/signal11/hidapi)
- [Swift-Keylogger - GitHub](https://github.com/SkrewEverything/Swift-Keylogger)

**Swift Interop**:
- [C Callbacks in Swift - Ole Begemann](https://oleb.net/blog/2015/06/c-callbacks-in-swift/)
- [Wrapping C Function Callbacks to Swift - Part 1](http://blog.raymccrae.scot/2018/09/wrapping-c-function-callbacks-to-swift-part-1/)

**HID Specifications**:
- [USB HID Keyboard Scan Codes - GitHub](https://gist.github.com/MightyPork/6da26e382a7ad91b5496ee55fdc73db2)
- [Keyboard/Keypad Page (0x07) - GitHub](https://gist.github.com/mildsunrise/4e231346e2078f440969cdefb6d4caa3)

---

## 14. Summary: Decision Matrix

| Requirement | Solution | Complexity | Permissions |
|-------------|----------|-----------|------------|
| Detect system keys (F3/F4) | CGEventTap `.listenOnly` | Low | Input Monitoring |
| Suppress system keys | CGEventTap `.default` or IOKit exclusive grab | High | Accessibility or DriverKit |
| Remap keys globally | Karabiner-like (IOKit + DriverKit) | Very High | DriverKit signing, root |
| Monitor all keyboard input | IOHIDManager | High | Input Monitoring |
| Per-app key detection | NSEvent/Cocoa | Very Low | None |

For Relux's use case (hotkey detection without suppression), **CGEventTap with Input Monitoring** is the optimal path forward.
