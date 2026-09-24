/* Minimal public build shim 鈥?runtime links real IOSurface.framework */
#ifndef IOSURFACE_REF_H_SHIM
#define IOSURFACE_REF_H_SHIM

#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifndef FourCharCode
typedef uint32_t FourCharCode;
#endif
#ifndef OSType
typedef FourCharCode OSType;
#endif

#ifdef __cplusplus
extern "C" {
#endif

typedef struct __IOSurface *IOSurfaceRef;
typedef uint32_t IOSurfaceID;

typedef CF_OPTIONS(uint32_t, IOSurfaceLockOptions) {
	kIOSurfaceLockReadOnly = 1,
	kIOSurfaceLockAvoidSync = 2
};

typedef CF_ENUM(int32_t, IOSurfaceMemoryMapPurgeability) {
	kIOSurfaceMapPurgeableKeepCurrent = -1,
	kIOSurfaceMapPurgeableNonVolatile = 0,
	kIOSurfaceMapPurgeableVolatile = 1,
	kIOSurfaceMapPurgeableEmpty = 2
};

enum {
	kIOMapDefaultCache = 0,
	kIOMapInhibitCache = 1
};

extern const CFStringRef kIOSurfaceAllocSize;
extern const CFStringRef kIOSurfaceWidth;
extern const CFStringRef kIOSurfaceHeight;
extern const CFStringRef kIOSurfaceBytesPerRow;
extern const CFStringRef kIOSurfaceBytesPerElement;
extern const CFStringRef kIOSurfaceElementWidth;
extern const CFStringRef kIOSurfaceElementHeight;
extern const CFStringRef kIOSurfaceOffset;
extern const CFStringRef kIOSurfacePlaneInfo;
extern const CFStringRef kIOSurfacePlaneWidth;
extern const CFStringRef kIOSurfacePlaneHeight;
extern const CFStringRef kIOSurfacePlaneBytesPerRow;
extern const CFStringRef kIOSurfacePlaneOffset;
extern const CFStringRef kIOSurfacePlaneSize;
extern const CFStringRef kIOSurfacePlaneBase;
extern const CFStringRef kIOSurfacePlaneBytesPerElement;
extern const CFStringRef kIOSurfacePlaneElementWidth;
extern const CFStringRef kIOSurfacePlaneElementHeight;
extern const CFStringRef kIOSurfaceCacheMode;
extern const CFStringRef kIOSurfaceIsGlobal;
extern const CFStringRef kIOSurfacePixelFormat;
extern const CFStringRef kIOSurfacePixelSizeCastingAllowed;

IOSurfaceRef IOSurfaceCreate(CFDictionaryRef properties);
IOSurfaceRef IOSurfaceLookup(IOSurfaceID cid);
IOSurfaceID IOSurfaceGetID(IOSurfaceRef buffer);

kern_return_t IOSurfaceLock(IOSurfaceRef buffer, IOSurfaceLockOptions options, uint32_t *seed);
kern_return_t IOSurfaceUnlock(IOSurfaceRef buffer, IOSurfaceLockOptions options, uint32_t *seed);

size_t IOSurfaceGetAllocSize(IOSurfaceRef buffer);
size_t IOSurfaceGetWidth(IOSurfaceRef buffer);
size_t IOSurfaceGetHeight(IOSurfaceRef buffer);
size_t IOSurfaceGetBytesPerElement(IOSurfaceRef buffer);
size_t IOSurfaceGetBytesPerRow(IOSurfaceRef buffer);
void *IOSurfaceGetBaseAddress(IOSurfaceRef buffer);
size_t IOSurfaceGetElementWidth(IOSurfaceRef buffer);
size_t IOSurfaceGetElementHeight(IOSurfaceRef buffer);
OSType IOSurfaceGetPixelFormat(IOSurfaceRef buffer);

size_t IOSurfaceGetPropertyMaximum(CFStringRef property);
size_t IOSurfaceGetPropertyAlignment(CFStringRef property);

bool IOSurfaceIsInUse(IOSurfaceRef buffer);
void IOSurfaceIncrementUseCount(IOSurfaceRef buffer);
void IOSurfaceDecrementUseCount(IOSurfaceRef buffer);
int32_t IOSurfaceGetUseCount(IOSurfaceRef buffer);

bool IOSurfaceSetPurgeable(IOSurfaceRef buffer, IOSurfaceMemoryMapPurgeability newState, IOSurfaceMemoryMapPurgeability *oldState);

#ifdef __cplusplus
}
#endif

#endif
