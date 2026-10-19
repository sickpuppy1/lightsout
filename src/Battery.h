// Battery level and power-source change notifications (IOKit power sources).
#import <Foundation/Foundation.h>

@interface LOBattery : NSObject

/// Battery charge 0-100 when the Mac is running on battery power; -1 on AC power or when there is no battery.
+ (NSInteger)percentWhenOnBattery;

/// Calls handler on the main thread whenever power info changes (plug/unplug, charge % change).
/// Returns an opaque token for stopWatching:.
+ (id)watch:(void (^)(void))handler;
+ (void)stopWatching:(id)token;

@end
