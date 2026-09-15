#import "SpaceSwitch.h"

#import <AppKit/AppKit.h>
#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>

typedef int32_t CGSConnectionID;
typedef CGSConnectionID (*CGSMainConnectionIDFn)(void);
typedef CFArrayRef (*CGSCopyManagedDisplaySpacesFn)(CGSConnectionID, CFStringRef);

// The WMBridge operation classes are private SkyLight classes; only their
// initializers differ, so declare the two shapes we dispatch.
@protocol ReluxSpacesOperation <NSObject>
- (instancetype)initWithSpaces:(NSArray<NSNumber *> *)spaces;
@end

@protocol ReluxSetCurrentSpaceOperation <NSObject>
- (instancetype)initWithDisplayIdentifier:(NSString *)displayIdentifier spaceID:(uint64_t)spaceID;
@end

static CGSMainConnectionIDFn ReluxMainConnectionID(void) {
    static CGSMainConnectionIDFn fn;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fn = (CGSMainConnectionIDFn)dlsym(RTLD_DEFAULT, "CGSMainConnectionID");
    });
    return fn;
}

static CGSCopyManagedDisplaySpacesFn ReluxCopyManagedDisplaySpaces(void) {
    static CGSCopyManagedDisplaySpacesFn fn;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fn = (CGSCopyManagedDisplaySpacesFn)dlsym(RTLD_DEFAULT, "CGSCopyManagedDisplaySpaces");
    });
    return fn;
}

// The WMBridge classes live in SkyLight; load it explicitly so the class
// lookups succeed even if nothing else in the app has pulled it in.
static void ReluxEnsureSkyLight(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW);
    });
}

static NSArray<NSDictionary *> *ReluxReadSpaces(CGSConnectionID connection) {
    CGSCopyManagedDisplaySpacesFn copy = ReluxCopyManagedDisplaySpaces();
    if (!copy) {
        return nil;
    }
    CFArrayRef displays = copy(connection, NULL);
    if (!displays) {
        return nil;
    }

    NSMutableArray<NSDictionary *> *spaces = [NSMutableArray array];
    for (NSDictionary *display in (__bridge NSArray *)displays) {
        NSString *identifier = display[@"Display Identifier"];
        NSNumber *currentID = ((NSDictionary *)display[@"Current Space"])[@"id64"];
        if (![identifier isKindOfClass:[NSString class]] || currentID == nil) {
            continue;
        }
        for (NSDictionary *space in display[@"Spaces"]) {
            NSNumber *spaceID = space[@"id64"];
            if (spaceID == nil) {
                continue;
            }
            [spaces addObject:@{
                @"id": spaceID,
                @"display": identifier,
                @"active": @([spaceID isEqual:currentID]),
            }];
        }
    }
    CFRelease(displays);
    return spaces;
}

static bool ReluxActivateSpace(NSDictionary *target, NSArray<NSDictionary *> *spaces) {
    Class showClass = objc_getClass("SLSBridgedShowSpacesOperation");
    Class hideClass = objc_getClass("SLSBridgedHideSpacesOperation");
    Class currentClass = objc_getClass("SLSBridgedManagedDisplaySetCurrentSpaceOperation");
    if (showClass == Nil || hideClass == Nil || currentClass == Nil) {
        return false;
    }

    // Setting the current Space alone updates the census but the compositor
    // keeps showing the old Space; the target must be shown and its display
    // siblings hidden for the switch to take effect.
    NSMutableArray<NSNumber *> *hidden = [NSMutableArray array];
    for (NSDictionary *space in spaces) {
        if ([space[@"display"] isEqual:target[@"display"]] && ![space[@"id"] isEqual:target[@"id"]]) {
            [hidden addObject:space[@"id"]];
        }
    }

    id<ReluxSpacesOperation> show = [(id<ReluxSpacesOperation>)[showClass alloc] initWithSpaces:@[target[@"id"]]];
    id<ReluxSpacesOperation> hide = [(id<ReluxSpacesOperation>)[hideClass alloc] initWithSpaces:hidden];
    id<ReluxSetCurrentSpaceOperation> current =
        [(id<ReluxSetCurrentSpaceOperation>)[currentClass alloc] initWithDisplayIdentifier:target[@"display"]
                                                                                  spaceID:[target[@"id"] unsignedLongLongValue]];
    if (show == nil || hide == nil || current == nil) {
        return false;
    }

    SEL perform = sel_registerName("performWithWMBridgeDelegate");
    ((void (*)(id, SEL))objc_msgSend)(show, perform);
    ((void (*)(id, SEL))objc_msgSend)(hide, perform);
    ((void (*)(id, SEL))objc_msgSend)(current, perform);
    return true;
}

bool ReluxSwitchSpace(int delta) {
    if (delta == 0) {
        return false;
    }
    ReluxEnsureSkyLight();

    CGSMainConnectionIDFn connectionFn = ReluxMainConnectionID();
    if (!connectionFn) {
        return false;
    }
    CGSConnectionID connection = connectionFn();
    if (connection == 0) {
        return false;
    }

    NSArray<NSDictionary *> *allSpaces = ReluxReadSpaces(connection);
    if (allSpaces.count == 0) {
        return false;
    }

    NSDictionary *active = nil;
    for (NSDictionary *space in allSpaces) {
        if ([space[@"active"] boolValue]) {
            active = space;
            break;
        }
    }
    if (active == nil) {
        return false;
    }

    // Step only within the active display's own ordered list of Spaces.
    NSMutableArray<NSDictionary *> *local = [NSMutableArray array];
    for (NSDictionary *space in allSpaces) {
        if ([space[@"display"] isEqual:active[@"display"]]) {
            [local addObject:space];
        }
    }
    NSInteger index = [local indexOfObjectIdenticalTo:active];
    NSInteger targetIndex = index + (delta > 0 ? 1 : -1);
    if (index == NSNotFound || targetIndex < 0 || targetIndex >= (NSInteger)local.count) {
        return false;
    }

    return ReluxActivateSpace(local[targetIndex], allSpaces);
}
