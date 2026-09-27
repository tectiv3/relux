#ifndef SpaceSwitch_h
#define SpaceSwitch_h

#include <stdbool.h>

/// Switches the active Space on the display under the cursor by `delta` steps
/// (+1 = next, -1 = previous) using SkyLight's native WMBridge operations.
/// Returns true if a switch was requested.
///
/// Uses the show/hide/set-current sequence that macOS 27 requires for the
/// compositor to actually activate the target Space. Synthetic dock-swipe
/// gestures (the pre-27 approach) are no longer honored by the Dock.
bool ReluxSwitchSpace(int delta);

#endif /* SpaceSwitch_h */
