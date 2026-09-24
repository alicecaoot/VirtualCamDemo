/* Minimal ObjC shim for CoreImage / public SDK builds */
#ifndef IOSURFACE_OBJC_H_SHIM
#define IOSURFACE_OBJC_H_SHIM

#import <Foundation/Foundation.h>
#import <IOSurface/IOSurfaceRef.h>

NS_ASSUME_NONNULL_BEGIN

@interface IOSurface : NSObject
- (instancetype)initWithProperties:(NSDictionary *)properties;
@property (readonly) NSUInteger width;
@property (readonly) NSUInteger height;
@property (readonly) void *baseAddress;
@property (readonly) NSUInteger bytesPerRow;
@property (readonly) NSUInteger bytesPerElement;
@property (readonly) OSType pixelFormat;
@property (readonly) IOSurfaceID surfaceID;
- (kern_return_t)lockWithOptions:(IOSurfaceLockOptions)options seed:(uint32_t *_Nullable)seed;
- (kern_return_t)unlockWithOptions:(IOSurfaceLockOptions)options seed:(uint32_t *_Nullable)seed;
@end

NS_ASSUME_NONNULL_END

#endif
