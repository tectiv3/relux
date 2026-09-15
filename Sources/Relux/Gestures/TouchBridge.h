#ifndef Relux_TouchBridge_h
#define Relux_TouchBridge_h

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Mirrors MTTouch as defined in the private MultitouchSupport.framework
// (reproduced from OpenMultitouchSupport's OpenMTInternal.h). The offset and
// size assertions in TouchBridge.c guard this layout against future changes.
typedef struct {
    float x;
    float y;
} ReluxMTPoint;

typedef struct {
    ReluxMTPoint position;
    ReluxMTPoint velocity;
} ReluxMTVector;

typedef struct {
    int frame;
    double timestamp;
    int identifier;
    int state;
    int fingerId;
    int handId;
    ReluxMTVector normalizedPosition;
    float total;
    float pressure;
    float angle;
    float majorAxis;
    float minorAxis;
    ReluxMTVector absolutePosition;
    int field14;
    int field15;
    float density;
} ReluxMTTouch;

// Flattened, Swift-facing contact. Only the fields the gesture engine consumes.
typedef struct {
    int32_t identifier;
    int32_t state;
    float x, y;
    float total, pressure, majorAxis, minorAxis;
} ReluxTouch;

typedef void (*ReluxTouchFrameHandler)(void *context, const ReluxTouch *touches, int count, double timestamp);

bool ReluxTouchStart(ReluxTouchFrameHandler handler, void *context);
void ReluxTouchStop(void);
bool ReluxTouchIsRunning(void);

#ifdef __cplusplus
}
#endif

#endif /* Relux_TouchBridge_h */
