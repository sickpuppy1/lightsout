// LightsOut: one menu bar click -> keyboard light 0, lock screen, display off.
// The Mac stays awake (so Claude Code / builds / downloads keep running) until you unlock.
#import <Cocoa/Cocoa.h>
#import <IOKit/pwr_mgt/IOPMLib.h>
#include <dlfcn.h>

// Private CoreBrightness class (macOS 10.12.4+); we only declare the methods we call.
@interface NSObject (KeyboardBrightnessClient)
- (NSArray *)copyKeyboardBacklightIDs;
- (float)brightnessForKeyboard:(unsigned long long)kid;
- (BOOL)setBrightness:(float)level forKeyboard:(unsigned long long)kid;
@end

// A finger still on the trackpad after the click wakes the display right back up, so:
static const NSTimeInterval kHandsOffSeconds = 1.0;  // trackpad/keyboard untouched this long before display off
static const NSTimeInterval kGuardSeconds = 10.0;    // re-darken if a stray touch wakes the display this soon after
static const NSTimeInterval kPollSeconds = 0.25;     // how often the guard checks

static NSString *const kLoginFramework = @"/System/Library/PrivateFrameworks/login.framework/Versions/Current/login";
static NSString *const kCGSession = @"/System/Library/CoreServices/Menu Extras/User.menu/Contents/Resources/CGSession";
static NSString *const kAgentLabel = @"com.lightsout.app";  // LaunchAgent that starts us at login
static NSString *const kDidSetUp = @"didSetUp";              // first-run flag in NSUserDefaults

@interface AppDelegate : NSObject <NSApplicationDelegate>
@property (strong) NSStatusItem *item;
@property (strong) id keyboard;                              // KeyboardBrightnessClient, nil if unavailable
@property (strong) NSMutableDictionary<NSNumber *, NSNumber *> *savedLevels;
@property (assign) IOPMAssertionID awake;
@property (assign) BOOL locked;
@property (strong) NSTimer *guard;
@property (strong) NSDate *lastOff;                          // last time we darkened (or the click)
@end

// Seconds since the last keyboard/trackpad/mouse event (the same idle clock screen savers use).
static double hidIdleSeconds(void) {
  io_service_t hid = IOServiceGetMatchingService(MACH_PORT_NULL, IOServiceMatching("IOHIDSystem"));
  if (!hid) return 1e9;
  CFTypeRef v = IORegistryEntryCreateCFProperty(hid, CFSTR("HIDIdleTime"), kCFAllocatorDefault, 0);
  IOObjectRelease(hid);
  uint64_t ns = 0;
  if (v) { CFNumberGetValue((CFNumberRef)v, kCFNumberSInt64Type, &ns); CFRelease(v); }
  return ns / 1e9;
}

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)n {
  if ([self relocateIfNeeded] || [self olderInstanceIsRunning]) { [NSApp terminate:nil]; return; }

  self.item = [NSStatusBar.systemStatusBar statusItemWithLength:NSSquareStatusItemLength];
  if (@available(macOS 11.0, *)) {
    NSImage *img = [NSImage imageWithSystemSymbolName:@"moon.zzz.fill" accessibilityDescription:@"LightsOut"];
    img.template = YES;
    self.item.button.image = img;
  } else {
    self.item.button.title = @"☾";
  }
  self.item.button.toolTip = @"LightsOut: keyboard light off, lock, screen off. Right-click for options.";
  self.item.button.target = self;
  self.item.button.action = @selector(clicked:);
  [self.item.button sendActionOn:NSEventMaskLeftMouseUp | NSEventMaskRightMouseUp];

  dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_NOW);
  Class K = NSClassFromString(@"KeyboardBrightnessClient");
  if (K) self.keyboard = [[K alloc] init];
  self.savedLevels = [NSMutableDictionary dictionary];

  [NSDistributedNotificationCenter.defaultCenter addObserver:self selector:@selector(unlocked:)
                                                        name:@"com.apple.screenIsUnlocked" object:nil];
  [NSWorkspace.sharedWorkspace.notificationCenter addObserver:self selector:@selector(screensWoke:)
                                                         name:NSWorkspaceScreensDidWakeNotification object:nil];

  NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
  if (![d boolForKey:kDidSetUp]) {
    [self setStartsAtLogin:YES];
    [d setBool:YES forKey:kDidSetUp];
    [self showWelcome];
  } else if (self.startsAtLogin) {
    [self setStartsAtLogin:YES];  // rewrite the path in case the app was moved
  }
}

#pragma mark - Setup (move out of the DMG, one instance, start at login)

// Opened straight from the DMG (/Volumes/...) or from a Gatekeeper "translocated" read-only copy:
// copy ourselves to /Applications (or ~/Applications), relaunch from there, and quit this copy.
- (BOOL)relocateIfNeeded {
  NSString *src = NSBundle.mainBundle.bundlePath;
  if (![src hasPrefix:@"/Volumes/"] && [src rangeOfString:@"/AppTranslocation/"].location == NSNotFound) return NO;

  for (NSRunningApplication *a in [self otherInstances]) [a terminate];  // an older version being upgraded
  [NSThread sleepForTimeInterval:1.0];

  NSFileManager *fm = NSFileManager.defaultManager;
  for (NSString *dir in @[@"/Applications", [NSHomeDirectory() stringByAppendingPathComponent:@"Applications"]]) {
    NSString *dst = [dir stringByAppendingPathComponent:src.lastPathComponent];
    [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    if ([fm fileExistsAtPath:dst] && ![fm removeItemAtPath:dst error:nil]) continue;
    if (![fm copyItemAtPath:src toPath:dst error:nil]) continue;
    // You already approved this app in Gatekeeper; don't make the copy ask again.
    [[self run:@"/usr/bin/xattr" args:@[@"-dr", @"com.apple.quarantine", dst]] waitUntilExit];
    [self run:@"/usr/bin/open" args:@[@"-n", dst]];
    return YES;
  }
  return NO;  // nowhere writable: keep running from where we are
}

- (NSArray<NSRunningApplication *> *)otherInstances {
  NSMutableArray *others = [NSMutableArray array];
  for (NSRunningApplication *a in [NSRunningApplication runningApplicationsWithBundleIdentifier:kAgentLabel])
    if (a.processIdentifier != getpid()) [others addObject:a];
  return others;
}

// Login launch + a double-click in Finder would give two moon icons; the newer process quits.
- (BOOL)olderInstanceIsRunning {
  for (NSRunningApplication *a in [self otherInstances])
    if ([a.bundleURL.path isEqualToString:NSBundle.mainBundle.bundlePath] && a.processIdentifier < getpid())
      return YES;
  return NO;
}

- (NSString *)agentPath {
  return [NSHomeDirectory() stringByAppendingFormat:@"/Library/LaunchAgents/%@.plist", kAgentLabel];
}

- (BOOL)startsAtLogin { return [NSFileManager.defaultManager fileExistsAtPath:self.agentPath]; }

// A LaunchAgent: a plist that launchd reads at every login. Works the same on every macOS version.
- (void)setStartsAtLogin:(BOOL)on {
  if (!on) { [NSFileManager.defaultManager removeItemAtPath:self.agentPath error:nil]; return; }
  [NSFileManager.defaultManager createDirectoryAtPath:self.agentPath.stringByDeletingLastPathComponent
                          withIntermediateDirectories:YES attributes:nil error:nil];
  NSDictionary *plist = @{
    @"Label": kAgentLabel,
    @"ProgramArguments": @[NSBundle.mainBundle.executablePath],
    @"RunAtLoad": @YES,
    @"KeepAlive": @{@"SuccessfulExit": @NO},  // restart after a crash, not after Quit
    @"LimitLoadToSessionType": @"Aqua",
  };
  [plist writeToFile:self.agentPath atomically:YES];
}

- (void)toggleStartsAtLogin:(id)sender { [self setStartsAtLogin:!self.startsAtLogin]; }

- (void)showWelcome {
  NSAlert *a = [NSAlert new];
  a.messageText = @"LightsOut is in your menu bar";
  a.informativeText = @"Click the moon icon to turn off the screen and keyboard light and lock your Mac. "
                       "Everything keeps running until you unlock.\n\n"
                       "It starts automatically at login. Right-click the icon for options.";
  [NSApp activateIgnoringOtherApps:YES];
  [a runModal];
}

#pragma mark - Menu bar

- (void)clicked:(id)sender {
  NSEvent *e = NSApp.currentEvent;
  if (e.type == NSEventTypeRightMouseUp || (e.modifierFlags & NSEventModifierFlagControl)) {
    NSMenu *m = [NSMenu new];
    NSMenuItem *login = [m addItemWithTitle:@"Start at Login" action:@selector(toggleStartsAtLogin:) keyEquivalent:@""];
    login.target = self;
    login.state = self.startsAtLogin ? NSControlStateValueOn : NSControlStateValueOff;
    [m addItem:NSMenuItem.separatorItem];
    [m addItemWithTitle:@"Quit LightsOut" action:@selector(terminate:) keyEquivalent:@""];
    [m popUpMenuPositioningItem:nil atLocation:NSMakePoint(0, NSHeight(self.item.button.bounds) + 4)
                         inView:self.item.button];
    return;
  }
  [self lightsOut];
}

- (void)lightsOut {
  [self keyboardLightOff];
  [self holdAwake];
  self.locked = [self lockScreen];
  self.lastOff = [NSDate date];
  [self.guard invalidate];
  self.guard = [NSTimer scheduledTimerWithTimeInterval:kPollSeconds target:self selector:@selector(guardTick:)
                                              userInfo:nil repeats:YES];
}

// Turns the display off once hands are off, and again if a stray touch wakes it within kGuardSeconds.
- (void)guardTick:(NSTimer *)t {
  NSTimeInterval sinceOff = -self.lastOff.timeIntervalSinceNow;
  if (sinceOff > kGuardSeconds) { [self stopGuard]; return; }  // stayed dark, or you kept touching: stop
  if (CGDisplayIsAsleep(CGMainDisplayID()) || hidIdleSeconds() < kHandsOffSeconds) return;
  [self run:@"/usr/bin/pmset" args:@[@"displaysleepnow"]];
  self.lastOff = [NSDate date];
}

- (void)stopGuard {
  [self.guard invalidate];
  self.guard = nil;
}

// Same lock as Ctrl+Cmd+Q (macOS 10.13+). Older macOS: fast-user-switching login window.
- (BOOL)lockScreen {
  void *login = dlopen(kLoginFramework.fileSystemRepresentation, RTLD_NOW);
  void (*lock)(void) = login ? (void (*)(void))dlsym(login, "SACLockScreenImmediate") : NULL;
  if (lock) { lock(); return YES; }
  if ([NSFileManager.defaultManager isExecutableFileAtPath:kCGSession]) {
    [self run:kCGSession args:@[@"-suspend"]];
    return YES;
  }
  NSLog(@"LightsOut: no lock method found on this macOS; display will still turn off");
  return NO;
}

- (void)keyboardLightOff {
  if (!self.keyboard) return;  // older macOS: the backlight still goes dark with the display
  for (NSNumber *kid in [self.keyboard copyKeyboardBacklightIDs]) {
    unsigned long long k = kid.unsignedLongLongValue;
    if (!self.savedLevels[kid]) self.savedLevels[kid] = @([self.keyboard brightnessForKeyboard:k]);
    [self.keyboard setBrightness:0.0f forKeyboard:k];
  }
}

- (void)keyboardLightRestore {
  for (NSNumber *kid in self.savedLevels)
    [self.keyboard setBrightness:self.savedLevels[kid].floatValue forKeyboard:kid.unsignedLongLongValue];
  [self.savedLevels removeAllObjects];
}

// Same as `caffeinate -i`: blocks idle *system* sleep but still lets the display sleep.
- (void)holdAwake {
  if (self.awake) return;
  IOPMAssertionID a = 0;
  if (IOPMAssertionCreateWithName(kIOPMAssertPreventUserIdleSystemSleep, kIOPMAssertionLevelOn,
        CFSTR("LightsOut: keep running while locked"), &a) == kIOReturnSuccess)
    self.awake = a;
}

- (void)welcomeBack {
  [self stopGuard];
  if (self.awake) IOPMAssertionRelease(self.awake);
  self.awake = 0;
  self.locked = NO;
  [self keyboardLightRestore];
}

- (void)unlocked:(NSNotification *)n { [self welcomeBack]; }

// Only used when we could not lock: no unlock event will come, so the display waking is the "I'm back" signal.
- (void)screensWoke:(NSNotification *)n { if (self.awake && !self.locked) [self welcomeBack]; }

- (NSTask *)run:(NSString *)path args:(NSArray *)args {
  NSTask *t = [NSTask new];
  t.launchPath = path;
  t.arguments = args;
  @try { [t launch]; } @catch (NSException *e) { NSLog(@"LightsOut: %@ failed: %@", path, e); return nil; }
  return t;
}

@end

int main(void) {
  @autoreleasepool {
    NSApplication *app = NSApplication.sharedApplication;
    app.activationPolicy = NSApplicationActivationPolicyAccessory;  // menu bar only, no Dock icon
    AppDelegate *d = [AppDelegate new];
    app.delegate = d;
    [app run];
  }
  return 0;
}
