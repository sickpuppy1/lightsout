#import "Battery.h"
#import <IOKit/ps/IOPowerSources.h>
#import <IOKit/ps/IOPSKeys.h>

// Private token returned by watch:. It keeps the handler and the run loop source together.
@interface LOBatteryWatch : NSObject
@property (nonatomic, copy) void (^handler)(void);
@property (nonatomic, assign) CFRunLoopSourceRef source;
@end

@implementation LOBatteryWatch
@end

// IOKit calls this on the run loop where the source was added (the main run loop).
static void LOBatteryChanged(void *context) {
  LOBatteryWatch *watch = (__bridge LOBatteryWatch *)context;
  dispatch_async(dispatch_get_main_queue(), ^{
    if (watch.handler) watch.handler();  // nil after stopWatching:, so a late callback does nothing
  });
}

@implementation LOBattery

+ (NSInteger)percentWhenOnBattery {
  CFTypeRef info = IOPSCopyPowerSourcesInfo();
  if (!info) return -1;
  NSInteger result = -1;

  CFStringRef providing = IOPSGetProvidingPowerSourceType(info);  // "Get" rule: do not release
  if (providing && CFEqual(providing, CFSTR(kIOPSBatteryPowerValue))) {
    CFArrayRef list = IOPSCopyPowerSourcesList(info);
    if (list) {
      for (CFIndex i = 0; i < CFArrayGetCount(list) && result < 0; i++) {
        CFDictionaryRef desc = IOPSGetPowerSourceDescription(info, CFArrayGetValueAtIndex(list, i));  // "Get" rule
        NSDictionary *d = (__bridge NSDictionary *)desc;
        if (!d || ![d[@kIOPSTypeKey] isEqualToString:@kIOPSInternalBatteryType]) continue;
        NSInteger cur = [d[@kIOPSCurrentCapacityKey] integerValue];
        NSInteger max = [d[@kIOPSMaxCapacityKey] integerValue];
        if (max > 0) result = cur * 100 / max;
      }
      CFRelease(list);
    }
  }

  CFRelease(info);
  return result;
}

+ (id)watch:(void (^)(void))handler {
  LOBatteryWatch *watch = [[LOBatteryWatch alloc] init];
  watch.handler = handler;
  CFRunLoopSourceRef source = IOPSNotificationCreateRunLoopSource(LOBatteryChanged, (__bridge void *)watch);
  if (!source) return nil;
  watch.source = source;
  CFRunLoopAddSource(CFRunLoopGetMain(), source, kCFRunLoopCommonModes);
  return watch;
}

+ (void)stopWatching:(id)token {
  if (![token isKindOfClass:LOBatteryWatch.class]) return;
  LOBatteryWatch *watch = token;
  if (watch.source) {
    CFRunLoopRemoveSource(CFRunLoopGetMain(), watch.source, kCFRunLoopCommonModes);
    CFRelease(watch.source);
    watch.source = NULL;
  }
  watch.handler = nil;
}

@end
