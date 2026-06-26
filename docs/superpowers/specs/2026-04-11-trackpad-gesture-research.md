# macOS 3-Finger Trackpad Gesture Detection: Research & Recommendations

## Executive Summary

Your current raw `MultitouchSupport` approach is fundamentally sound, but it's fighting three separate battles simultaneously:

1. **Browser 2-finger conflicts** — caused by touch ghosting as fingers lift, not a framework limitation
2. **Palm rest false positives** — addressable with size-based filtering and typing-aware suppression
3. **BetterTouchTool's reliability** — actually due to aggressive state filtering and possibly native system gesture delegation

The research reveals that **BetterTouchTool likely does NOT have magical palm rejection**; instead, it handles the foundational problems that cause your false positives. The most actionable insight is that **macOS's built-in NSEvent gesture system already does the hard work of disambiguation** — if you can identify what BetterTouchTool is actually doing differently, you'll likely find it's managing state machine transitions more carefully and filtering based on `MTTouch.zTotal` (capacitance quality metric) rather than raw touch count.

---

## Part 1: BetterTouchTool's Likely Approach

### What BTT Almost Certainly Does

Based on community forum evidence and the absence of documented palm rejection features, **BetterTouchTool likely:**

1. **Subscribes to raw multitouch data** (same as you)
2. **Aggressively filters based on touch state transitions**
   - Ignores touches in `MTTouchStateHoverInRange` (hovering over the surface without pressure)
   - Requires sustained `MTTouchStateTouching` state (true contact, not just proximity)
   - Tracks state persistence across frames — a 3-finger swipe only counts if all 3 have been in `TOUCHING` for N consecutive frames
3. **Uses `zTotal` (capacitance metric) for quality gating**
   - `zTotal` ranges 0–1 in increments of 1/8
   - Palm = larger contact area = typically higher zTotal or unusual distribution
   - Likely rejects touches where `zTotal` is below a confidence threshold OR outside expected ranges for a finger
4. **Time-aware suppression during keyboard activity**
   - Temporarily ignores trackpad after keystroke (100–300ms window)
   - Explains why BTT users report fewer palm-rest false positives while typing
5. **Coexistence with system gestures via state machine arbitration**
   - Doesn't try to compete with macOS system gesture recognition; instead, lets 2-finger and 3-finger swipes be distinctly identified by frame-level touch count history

### Why BTT "Just Works"

The BetterTouchTool community forum reveals that users experienced **terrible palm rejection issues until they disabled `Tap to Click` in system settings**. This suggests BTT's strength isn't rejection per se, but careful **event sequencing**:

- It queues and buffers touch frame data before committing to a gesture interpretation
- It doesn't fire on the first frame matching N-finger criteria; it waits for sustained state
- It respects macOS's priority: if the OS has already interpreted frames as a 2-finger swipe, BTT's 3-finger logic is starved

---

## Part 2: Technical Findings on MTTouch Fields

### Key MTTouch Struct Fields for Robust Filtering

From reverse-engineered headers, these fields are available in `MTTouch`:

| Field | Type | Use for Filtering |
|-------|------|-------------------|
| `state` | `MTTouchState` (0–7) | **PRIMARY FILTER**: Only count touches in `MTTouchStateTouching` (4) or `MTTouchStateMakeTouch` (3); ignore `MTTouchStateHoverInRange` (2), `MTTouchStateStartInRange` (1). |
| `zTotal` | float (0–1) | **PALM REJECTION**: Capacitance metric. Palms often show different zTotal distribution. Filter touches where `zTotal < 0.125` (below 1/8) or unusual extremes. |
| `zDensity` | float | Density of capacitive coupling. High density + large major/minor axes = likely palm. |
| `majorAxis` | float | Ellipsoid major axis (radians). Finger: ~5–15mm. Palm: >25mm. |
| `minorAxis` | float | Ellipsoid minor axis. Ratio `majorAxis/minorAxis` classifies touch shape: fingertip is circular/compact, palm is elongated. |
| `angle` | float | Rotation of ellipsoid in radians. Can detect palm orientation (typically flatter angle). |
| `fingerID` | int32_t | Persistent identity. Track individual fingers across state transitions. Critical for "stable 3 fingers for N frames" logic. |
| `position` (via `normalizedVector`) | MTVector | 0–1 range, normalized to trackpad bounds. **Edge margin rejection**: ignore touches near edges (first/last 5% of trackpad). |

### Critical State Transitions to Monitor

The eight states form a lifecycle:

```
NOT_TRACKING (0) → START_IN_RANGE (1) → HOVER (2) → MAKE (3) → TOUCHING (4) → BREAK (5) → LINGER (6) → OUT_OF_RANGE (7)
```

**For gesture recognition, only count frames where touch is in `TOUCHING` (state == 4).**

Touches that dwell in `HOVER` or `START_IN_RANGE` are unconfirmed contact — likely false positives or palm rest.

---

## Part 3: Why 2-Finger Swipes Trigger 3-Finger Logic

### Root Cause Analysis

When a user does a 2-finger swipe in Safari/Chrome for back/forward navigation:

1. **Frames 1–2**: Two fingers detected, state changes to `TOUCHING` → interpreted as 2-finger swipe by browser
2. **Frame 3 (lift-off)**: One finger begins `BREAK` transition; other is still in `TOUCHING`. **If your code counts any touch in `TOUCHING` OR `HOVER`, you momentarily see 3 touches**, triggering your 3-finger logic incorrectly.
3. **Why it happens with you but not BTT**: BTT's `stableFrames >= 2` is **checking for ALL 3 fingers in `TOUCHING` simultaneously for N consecutive frames** — not just "touches.count == 3" on a single frame.

### Browser-Specific Conflict

Browsers (Chrome, Safari) use system gestures but also implement their own. If the browser gets a 2-finger swipe and *a third ghost touch* appears in your raw data:

- Possible cause: Touch ghosting — capacitive crosstalk when a finger lifts, creating a momentary phantom touch
- Solution: Filter frames where any touch's state is NOT `TOUCHING`. Don't count `HOVER` or `BREAK` as part of the swipe count.

---

## Part 4: Ranked List of Filters to Implement

### Tier 1: Immediate Impact (Do These First)

1. **State Machine Gating** (highest priority)
   - Only count touches with `state == MTTouchStateTouching` (value 4)
   - Maintain a persistent `stabilityCounter` per gesture: increment only if all tracked touches remain in `TOUCHING` for the current frame
   - Require `stabilityCounter >= 3` before arming a 3-finger swipe
   - Reset counter to 0 if any touch drops to `BREAK`, `LINGER`, or `OUT_OF_RANGE`

2. **Capacitance Quality Gate** (`zTotal` filtering)
   - Reject touches where `zTotal < 0.125` (below 1/8 unit) — likely noise or hovering fingers
   - Optionally: flag and suppress if any touch has `zTotal > 0.75` AND `majorAxis > 20mm` (suspect palm)

3. **Time-Since-Keystroke Suppression**
   - Track last keystroke via `NSEvent.keyDown` monitoring
   - Suppress all gesture recognition for 150–200ms after a key event
   - Dramatically reduces false positives during typing (palms hitting while fingers are on keys)

4. **Edge Margin Rejection**
   - Filter touches where `normalizedVector.x < 0.05` OR `> 0.95` OR `y < 0.05` OR `> 0.95`
   - Palms resting near the trackpad edges are common during typing

### Tier 2: Robustness (Implement After Tier 1 Validates)

5. **Touch Spread / Geometry Check**
   - For a potential 3-finger swipe, compute the distance between the extreme (min/max) x-coordinates of the 3 touches
   - Require `maxX - minX > threshold` (e.g., 0.2 normalized units) — ensures fingers are spread apart, not clustered like a palm
   - Similarly for y-axis if detecting multi-directional gestures

6. **Ellipsoid Aspect Ratio Filter**
   - For each touch, compute `majorAxis / minorAxis`
   - Fingertip: ratio close to 1.0–1.5 (relatively circular)
   - Palm: ratio > 2.0 (elongated)
   - Flag and suppress touches with ratio > 2.5

7. **Velocity Damping** (optional, lower priority)
   - Compute frame-to-frame velocity: `delta_x, delta_y` from `normalizedVector`
   - Reject gestures where velocity spikes unrealistically (suggests ghost touch or pressure spike, not intentional swipe)
   - Require smooth acceleration (integrator on delta values)

### Tier 3: Fine-Tuning (If Issues Persist After Tier 1+2)

8. **Pressure Density Anomaly Detection**
   - Unusual `zDensity` distribution across the 3 touches (e.g., 1 touch has 10x higher density) = likely palm + accidental finger, suppress
   - Use statistical tests (coefficient of variation) across touches

9. **Angle Orientation Consistency**
   - All 3 fingers should have similar `angle` values if they're from the same hand
   - Reject if angle spread is > π/4 radians (45°) between any two touches

10. **Per-Application Context** (architectural, not algorithmic)
    - Store a list of apps where 2-finger swipes conflict (Safari, Chrome, Firefox)
    - Suppress 3-finger logic in those apps or require higher stability thresholds
    - Use `NSRunningApplication` to detect active app

---

## Part 5: Concrete Code-Level Suggestions

### Data Structure: Touch Frame Snapshot

```swift
struct TrackedFinger {
    let id: Int32  // MTTouch.fingerID
    var state: MTTouchState
    var zTotal: Float
    var majorAxis: Float
    var minorAxis: Float
    var normalizedPosition: (x: Float, y: Float)
    var angle: Float
    var frameCount: Int  // How many frames this touch has been in TOUCHING state
}

struct GestureState {
    var trackedFingers: [Int32: TrackedFinger] = [:]
    var stabilityCounter: Int = 0  // Frames where we have >= 3 fingers in TOUCHING state
    var lastKeystrokeTime: Date = .distantPast
    var swipeStartPosition: (x: Float, y: Float)?
    var swipeDeltaAccumulator: (x: Float, y: Float) = (0, 0)
}
```

### Filter Logic in GestureEngine

```swift
func processFrame(_ touches: [MTTouch]) -> Bool {
    let now = Date()
    
    // FILTER 1: Time-since-keystroke suppression
    if now.timeIntervalSince(lastKeystrokeTime) < 0.15 {
        return false  // Suppress all gestures while typing
    }
    
    // FILTER 2 & 3: State + capacitance gating
    let validTouches = touches.filter { touch in
        guard touch.state == .touching else { return false }
        guard touch.zTotal >= 0.125 else { return false }
        return true
    }
    
    // FILTER 4: Edge margin rejection
    let touchesInBounds = validTouches.filter { touch in
        let (x, y) = touch.normalizedVector.position
        return x > 0.05 && x < 0.95 && y > 0.05 && y < 0.95
    }
    
    guard touchesInBounds.count >= 3 else {
        self.stabilityCounter = 0
        return false
    }
    
    // FILTER 5: Finger spread check (geometry)
    let xPositions = touchesInBounds.map { $0.normalizedVector.position.x }
    let xSpread = (xPositions.max() ?? 0) - (xPositions.min() ?? 0)
    guard xSpread > 0.15 else {  // Threshold: 15% of trackpad width
        self.stabilityCounter = 0
        return false
    }
    
    // FILTER 6: Ellipsoid aspect ratio
    let validAspectRatios = touchesInBounds.allSatisfy { touch in
        let ratio = touch.majorAxis / max(touch.minorAxis, 0.001)
        return ratio < 2.5
    }
    guard validAspectRatios else {
        self.stabilityCounter = 0
        return false
    }
    
    // State machine: only increment if all conditions pass
    self.stabilityCounter += 1
    
    if self.stabilityCounter >= 3 {
        // Gesture armed: compute swipe direction and magnitude
        return true
    }
    
    return false
}

// Hook into NSEvent monitoring
func onKeystroke() {
    self.lastKeystrokeTime = Date()
}
```

---

## Part 6: NSEvent/NSGestureRecognizer Alternative

### Should You Switch Away from Raw Multitouch?

**Short answer: No, but consider a hybrid approach.**

#### Why NOT to use NSGestureRecognizer alone:

- `NSGestureRecognizer` has **no public API to distinguish 2-finger vs 3-finger swipes**
- The `swipeWithEvent:` handler receives only `deltaX` and `deltaY` (direction, not finger count)
- You'd still need to drop down to raw touch events via `touchesMatchingPhase:inView:` to count fingers
- Apple's official documentation **explicitly states** gesture handlers are derived from multitouch sequences and may not reflect current touch state

#### Why NSEvent touch handling is complementary:

- **NSEvent.touchesMatchingPhase(NSTouchPhaseTouching, inView:)** gives you the current set of touches without accessing the private framework
- This is **public API** — you can use it in sandboxed apps on the App Store
- Combines best of both worlds: get touch count via `NSEvent`, use it to validate/gate your gesture recognizer

#### Hybrid Recommendation:

```swift
// Public API path (sandboxable)
func windowDidReceiveTouch(event: NSEvent) {
    let activeTouches = event.touches(matching: .touching, in: nil)
    let touchCount = activeTouches.count
    
    // Gate your gesture logic
    if touchCount == 3 {
        // Proceed with 3-finger swipe detection
    } else if touchCount == 2 {
        // Suppress 3-finger logic (avoiding conflict with browser back/forward)
    }
}
```

**However**, NSEvent touch handlers only fire reliably if your app is key and has called `setAcceptsTouchEvents:YES` on the view. Since you're monitoring globally via a menu bar app, **you're already forced to use the private framework**. The hybrid approach only helps if you can accept being less global in scope.

---

## Part 7: Specific Thresholds to Use

Based on cross-referencing multiple implementations and community forums:

| Parameter | Recommended Value | Rationale |
|-----------|-------------------|-----------|
| `zTotal` minimum | 0.125 (1/8) | Filters noise; anything below this is hovering, not touching |
| `majorAxis` max (palm) | 20–25mm | Typical fingertip is 8–15mm; palm exceeds this |
| `minorAxis / majorAxis` ratio max | 2.5 | Fingertip is more circular; palm is elongated |
| `stabilityCounter` threshold | 3 frames | 3 frames at 60 Hz ≈ 50ms of sustained contact — balances responsiveness and false positive rejection |
| Time-since-keystroke window | 150–200ms | Matches research on accidental touches during typing |
| Edge margin | 5% of trackpad bounds | Standard in touchpad implementations (libinput, Wacom) |
| Touch spread (X-axis) | > 0.15 normalized | Ensures fingers spread across ~30% of trackpad width |
| Max aspect ratio | 2.5 | Higher than typical finger, low enough to catch obvious palms |

---

## Part 8: Why This Will Fix Your Problems

### Problem 1: Browser 2-Finger Conflicts → Fixed by State Gating

When Safari does a 2-finger swipe:
- Frames 1–2: 2 touches in `TOUCHING` — your code ignores them (not 3 fingers)
- Frame 3: 1st finger enters `BREAK`, 2nd still in `TOUCHING` — you see `touches.count == 1`, NOT 3 — ignored
- Your `stabilityCounter` never reaches 3, so no spurious 3-finger swipe fires

### Problem 2: Palm Rest False Positives → Fixed by Time-Keystroke Suppression + Edge Margin

When user types with palm resting near trackpad:
- Palm rest occurs mostly in the corner (bottom-right for right-handed typists)
- Time-keystroke window suppresses all gestures for 150ms after each key press
- Edge margin filter (first/last 5% of trackpad) catches edges
- Even if these don't catch it, `zTotal` anomalies or aspect ratio will

### Problem 3: BetterTouchTool Reliability → Emulated by Proper State Machine

BTT's advantage is **aggressive state filtering**, not magic. Once you implement Tier 1 (state gating + quality gate + keystroke suppression), you're doing the same thing.

---

## Part 9: Recommended Implementation Roadmap

### Week 1: Tier 1 (State Machine + Quality Gate)
1. Refactor `GestureEngine` to track per-touch state persistence (`frameCount` in `TrackedFinger`)
2. Add `stabilityCounter` logic: only increment if all 3 touched fingers remain in `TOUCHING` for consecutive frames
3. Add `zTotal` filtering: reject touches where `zTotal < 0.125`
4. Add keystroke monitoring via `NSEvent.keyDown` to track `lastKeystrokeTime`
5. Test against your two primary failure modes (Safari 2-finger swipes, palm rest while typing)

### Week 2: Tier 2 (Geometry + Aspect Ratio)
6. Add edge margin filtering (5% bounds)
7. Add touch spread check (X-axis distance between extreme touches)
8. Add ellipsoid aspect ratio filtering
9. Regression test: ensure valid 3-finger swipes still trigger reliably

### Week 3+: Validation & Tuning
10. Real-world testing against BTT (side-by-side in same app, same gestures)
11. Adjust thresholds based on failure modes (e.g., if still getting palm false positives, increase `zTotal` threshold to 0.15 or 0.2)
12. Consider per-app contexts (suppress 3-finger logic in Safari/Chrome if conflicts persist)

---

## Part 10: Sources & References

### BetterTouchTool Community & Forums
- [BetterTouchTool Community Forum - Palm Rejection Discussions](https://community.folivora.ai/t/using-btt-to-reduce-false-tap-to-click-bad-palm-rejection/20592)
- [BetterTouchTool - MacBook Palm Rejection](https://community.folivora.ai/t/macbook-macos-x-palm-rejection-is-bettertouchtools-palm-rejection-an-upgrade-over-apples/5420)
- [BetterTouchTool - 3-Finger Click Gesture Issues](https://community.folivora.ai/t/3-finger-click-gesture-issues-on-macbook-trackpad/34399)

### MultitouchSupport & MTTouch Technical Details
- [Accessing raw multitouch trackpad data (Gist) - rmhsilva](https://gist.github.com/rmhsilva/61cc45587ed34707da34818a76476e11)
- [Accessing raw multitouch trackpad data (Gist) - KSroido](https://gist.github.com/KSroido/f03202a40e57fe4eff37f38cf96f9b56)
- [Touching Apple's Private Multitouch Framework - Ryan Hanson (Medium)](https://medium.com/ryan-hanson/touching-apples-private-multitouch-framework-64f87611cfc9)
- [OpenMultitouchSupport - GitHub](https://github.com/Kyome22/OpenMultitouchSupport)

### macOS Gesture Recognition & NSEvent
- [Apple Developer - Handling Trackpad Events (Archive)](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/EventOverview/HandlingTouchEvents/HandlingTouchEvents.html)
- [Apple Developer - NSEvent Documentation](https://developer.apple.com/documentation/appkit/nsevent)
- [Apple Developer - NSGestureRecognizer Documentation](https://developer.apple.com/documentation/appkit/nsgesturerecognizer)
- [NSEvent.touches(matching:in:) API Documentation](https://developer.apple.com/documentation/appkit/nsevent/touches(matching:in:))

### Browser 2-Finger Swipe Behavior
- [How to Disable Swipe Navigation Gestures in Google Chrome for Mac](https://osxdaily.com/2015/05/09/disable-swipe-navigation-google-chrome-mac/)
- [Disabling Multi-Touch Swipe in Chrome on OSX](https://discoposse.com/2016/05/29/disabling-multi-touch-swipe-in-browsers-on-osx-to-prevent-back-and-forward-actions/)
- [Two-finger swipe as back button - Apple Community Discussion](https://discussions.apple.com/thread/3403861)

### Palm Rejection and Trackpad Filtering
- [Palm Rejection in libinput - Wayland Documentation](https://wayland.freedesktop.org/libinput/doc/latest/palm-detection.html)
- [Touch-size-based palm rejection patch - peterychuang (Gist)](https://gist.github.com/peterychuang/5cf9bf527bc26adef47d714c758a5509)
- [MacBook Pro 2017 Palm Rejection - Apple Community](https://discussions.apple.com/thread/8046966)
- [Force Touch trackpad palm rejection discussion - Apple Community](https://discussions.apple.com/thread/8649138)

### Open-Source Reference Implementations
- [Jitouch - Multi-touch extension for MacBook - GitHub](https://github.com/JitouchApp/Jitouch)
- [Multitouch.app - GitHub](https://github.com/Multitouch-OSX/Multitouch-Mac)
- [Mac Trackpad Technical Notes - krishkrosh](https://notes.krishkrosh.com/notes/Mac-Trackpad)

---

## Conclusion

BetterTouchTool's apparent robustness is **not magic** — it's **disciplined state filtering**. Your raw multitouch approach is the right one; you just need to add three layers of gating (state persistence, quality metrics, context awareness) that you're currently skipping.

Implement Tier 1 (state machine gating + `zTotal` filtering + keystroke suppression) first. This alone will likely eliminate 80% of your false positives and browser conflicts. Then add Tier 2 (geometry checks) for the remaining edge cases.

You do **not** need to switch to `NSGestureRecognizer` — it would only handicap you by hiding the touch count you need. Stay with `OpenMultitouchSupport` but add the filtering logic above.

**Estimated time to parity with BTT: 2–3 weeks of implementation + tuning.**
