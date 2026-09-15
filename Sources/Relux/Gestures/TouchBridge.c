#include "TouchBridge.h"

#include <dlfcn.h>
#include <stddef.h>

// --- ABI layout guards ----------------------------------------------------
// These mirror the private MultitouchSupport.framework MTTouch layout. If Apple
// changes it, compilation fails here instead of silently reading garbage.
_Static_assert(offsetof(ReluxMTTouch, frame) == 0, "unexpected MTTouch.frame offset");
_Static_assert(offsetof(ReluxMTTouch, timestamp) == 8, "unexpected MTTouch.timestamp offset");
_Static_assert(offsetof(ReluxMTTouch, identifier) == 16, "unexpected MTTouch.identifier offset");
_Static_assert(offsetof(ReluxMTTouch, state) == 20, "unexpected MTTouch.state offset");
_Static_assert(offsetof(ReluxMTTouch, fingerId) == 24, "unexpected MTTouch.fingerId offset");
_Static_assert(offsetof(ReluxMTTouch, handId) == 28, "unexpected MTTouch.handId offset");
_Static_assert(offsetof(ReluxMTTouch, normalizedPosition) == 32, "unexpected MTTouch.normalizedPosition offset");
_Static_assert(offsetof(ReluxMTTouch, total) == 48, "unexpected MTTouch.total offset");
_Static_assert(offsetof(ReluxMTTouch, pressure) == 52, "unexpected MTTouch.pressure offset");
_Static_assert(offsetof(ReluxMTTouch, angle) == 56, "unexpected MTTouch.angle offset");
_Static_assert(offsetof(ReluxMTTouch, majorAxis) == 60, "unexpected MTTouch.majorAxis offset");
_Static_assert(offsetof(ReluxMTTouch, minorAxis) == 64, "unexpected MTTouch.minorAxis offset");
_Static_assert(offsetof(ReluxMTTouch, absolutePosition) == 68, "unexpected MTTouch.absolutePosition offset");
_Static_assert(offsetof(ReluxMTTouch, field14) == 84, "unexpected MTTouch.field14 offset");
_Static_assert(offsetof(ReluxMTTouch, field15) == 88, "unexpected MTTouch.field15 offset");
_Static_assert(offsetof(ReluxMTTouch, density) == 92, "unexpected MTTouch.density offset");
_Static_assert(sizeof(ReluxMTTouch) == 96, "unexpected MTTouch size");
_Static_assert(sizeof(ReluxTouch) == 32, "unexpected ReluxTouch size");

#define RELUX_FRAMEWORK_PATH "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"

#define RELUX_MAX_TOUCHES 32

// The framework's own callback typedef returns void, but the classic ABI
// contract is int32_t returning 0 to keep the frame flowing to the system
// recognizer. A void-returning callback leaves whatever happened to be in the
// return register; on macOS 27 that garbage is read as "consume", which
// suppresses the native 3/4-finger gestures. This return type is the whole
// reason this bridge exists.
typedef int32_t (*ReluxMTFrameCallback)(void *device, ReluxMTTouch *touches, int numTouches, double timestamp, int frame);

typedef void *(*ReluxMTDeviceCreateDefault)(void);
typedef void (*ReluxMTRegisterContactFrameCallback)(void *device, ReluxMTFrameCallback callback);
typedef void (*ReluxMTUnregisterContactFrameCallback)(void *device, ReluxMTFrameCallback callback);
typedef int32_t (*ReluxMTDeviceStart)(void *device, int mode);
typedef int32_t (*ReluxMTDeviceStop)(void *device);
typedef void (*ReluxMTDeviceRelease)(void *device);

static void *relux_framework_handle = NULL;
static void *relux_device = NULL;
static ReluxTouchFrameHandler relux_handler = NULL;
static void *relux_context = NULL;
static bool relux_running = false;

static ReluxMTDeviceCreateDefault relux_create_default = NULL;
static ReluxMTRegisterContactFrameCallback relux_register_callback = NULL;
static ReluxMTUnregisterContactFrameCallback relux_unregister_callback = NULL;
static ReluxMTDeviceStart relux_device_start = NULL;
static ReluxMTDeviceStop relux_device_stop = NULL;
static ReluxMTDeviceRelease relux_device_release = NULL;

// Fires on the MultitouchSupport device's own thread, not the main thread.
static int32_t relux_contact_frame_callback(void *device, ReluxMTTouch *touches, int numTouches, double timestamp, int frame) {
    (void)device;
    (void)frame;

    ReluxTouchFrameHandler handler = relux_handler;
    if (handler == NULL) {
        return 0;
    }

    ReluxTouch flattened[RELUX_MAX_TOUCHES];
    int count = numTouches;
    if (count < 0) {
        count = 0;
    }
    if (count > RELUX_MAX_TOUCHES) {
        count = RELUX_MAX_TOUCHES;
    }

    for (int i = 0; i < count; i++) {
        ReluxMTTouch *touch = &touches[i];
        flattened[i].identifier = touch->identifier;
        flattened[i].state = touch->state;
        flattened[i].x = touch->normalizedPosition.position.x;
        flattened[i].y = touch->normalizedPosition.position.y;
        flattened[i].total = touch->total;
        flattened[i].pressure = touch->pressure;
        flattened[i].majorAxis = touch->majorAxis;
        flattened[i].minorAxis = touch->minorAxis;
    }

    handler(relux_context, flattened, count, timestamp);

    return 0;
}

static bool relux_resolve_symbols(void) {
    relux_create_default = (ReluxMTDeviceCreateDefault)dlsym(relux_framework_handle, "MTDeviceCreateDefault");
    relux_register_callback = (ReluxMTRegisterContactFrameCallback)dlsym(relux_framework_handle, "MTRegisterContactFrameCallback");
    relux_unregister_callback = (ReluxMTUnregisterContactFrameCallback)dlsym(relux_framework_handle, "MTUnregisterContactFrameCallback");
    relux_device_start = (ReluxMTDeviceStart)dlsym(relux_framework_handle, "MTDeviceStart");
    relux_device_stop = (ReluxMTDeviceStop)dlsym(relux_framework_handle, "MTDeviceStop");
    relux_device_release = (ReluxMTDeviceRelease)dlsym(relux_framework_handle, "MTDeviceRelease");

    return relux_create_default != NULL
        && relux_register_callback != NULL
        && relux_unregister_callback != NULL
        && relux_device_start != NULL
        && relux_device_stop != NULL
        && relux_device_release != NULL;
}

bool ReluxTouchStart(ReluxTouchFrameHandler handler, void *context) {
    if (handler == NULL) {
        return false;
    }

    if (relux_running) {
        relux_handler = handler;
        relux_context = context;
        return true;
    }

    if (relux_framework_handle == NULL) {
        relux_framework_handle = dlopen(RELUX_FRAMEWORK_PATH, RTLD_NOW);
        if (relux_framework_handle == NULL) {
            return false;
        }
    }

    if (!relux_resolve_symbols()) {
        return false;
    }

    void *device = relux_create_default();
    if (device == NULL) {
        return false;
    }

    relux_device = device;
    relux_handler = handler;
    relux_context = context;

    relux_register_callback(device, relux_contact_frame_callback);
    relux_device_start(device, 0);
    relux_running = true;
    return true;
}

void ReluxTouchStop(void) {
    if (relux_running && relux_device != NULL) {
        if (relux_unregister_callback != NULL) {
            relux_unregister_callback(relux_device, relux_contact_frame_callback);
        }
        if (relux_device_stop != NULL) {
            relux_device_stop(relux_device);
        }
        if (relux_device_release != NULL) {
            relux_device_release(relux_device);
        }
    }

    relux_device = NULL;
    relux_handler = NULL;
    relux_context = NULL;
    relux_running = false;
}

bool ReluxTouchIsRunning(void) {
    return relux_running;
}
