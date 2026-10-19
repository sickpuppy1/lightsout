// LightsOut: one menu bar click (or keyboard shortcut) -> keyboard light 0, lock screen, display off.
// The Mac stays awake (so Claude Code / builds / downloads keep running) until you unlock.
#import <Cocoa/Cocoa.h>
#import <IOKit/pwr_mgt/IOPMLib.h>
#include <dlfcn.h>
#import "Battery.h"
#import "Hotkey.h"
#import "Keys.h"
#import "LidMode.h"
#import "SettingsWindowController.h"

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

@interface AppDelegate : NSObject <NSApplicationDelegate, LOSettingsDelegate>
@property (strong) NSStatusItem *item;
@property (strong) LOSettingsWindowController *settings;
@property (strong) id keyboard;                              // KeyboardBrightnessClient, nil if unavailable
@property (strong) NSMutableDictionary<NSNumber *, NSNumber *> *savedLevels;
@property (assign) IOPMAssertionID awake;
@property (strong) id batteryWatch;
@property (assign) BOOL locked;
@property (strong) NSTimer *guard;
@property (strong) NSDate *lastOff;                          // last time we darkened (or the click)
@property (strong) dispatch_source_t sigterm;
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

  // Starting up means no lights-out session is active: if a crash, force-quit or restart left sleep
  // disabled, turn it back on now.
  [[LOLidMode shared] disengage];

  self.item = [NSStatusBar.systemStatusBar statusItemWithLength:NSSquareStatusItemLength];
  if (@available(macOS 11.0, *)) {
    NSImage *img = [NSImage imageWithSystemSymbolName:@"moon.zzz.fill" accessibilityDescription:@"LightsOut"];
    img.template = YES;
    self.item.button.image = img;
  } else {
    self.item.button.title = @"☾";
  }
  self.item.button.toolTip = @"LightsOut: keyboard light off, lock, screen off. Right-click for Settings.";
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

  // launchd stops us with SIGTERM (logout, `launchctl bootout`); quit cleanly so sleep gets restored.
  signal(SIGTERM, SIG_IGN);
  self.sigterm = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGTERM, 0, dispatch_get_main_queue());
  dispatch_source_set_event_handler(self.sigterm, ^{ [NSApp terminate:nil]; });
  dispatch_resume(self.sigterm);

  [self registerSavedShortcut];

  NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
  if (![d boolForKey:LOKeyDidSetUp]) {
    [self setStartsAtLogin:YES];
    [d setBool:YES forKey:LOKeyDidSetUp];
    [self showWelcome];
  } else if (self.startsAtLogin) {
    [self setStartsAtLogin:YES];  // rewrite the path in case the app was moved
  }
}

- (void)applicationWillTerminate:(NSNotification *)n {
  [self welcomeBack];
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

- (void)showWelcome {
  NSAlert *a = [NSAlert new];
  a.messageText = @"LightsOut is in your menu bar";
  a.informativeText = @"Click the moon icon to turn off the screen and keyboard light and lock your Mac. "
                       "Everything keeps running until you unlock.\n\n"
                       "Right-click the icon for Settings: add a keyboard shortcut, or let your Mac keep "
                       "running with the lid closed.";
  [NSApp activateIgnoringOtherApps:YES];
  [a runModal];
}

#pragma mark - Keyboard shortcut and Settings

- (void)registerSavedShortcut {
  NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
  NSInteger code = [d objectForKey:LOKeyHotkeyCode] ? [d integerForKey:LOKeyHotkeyCode] : -1;
  if (code < 0) { [[LOHotkey shared] unregister]; return; }
  NSEventModifierFlags mods = (NSEventModifierFlags)[d integerForKey:LOKeyHotkeyModifiers];
  if (![self registerShortcutKeyCode:code modifiers:mods])
    NSLog(@"LightsOut: shortcut %@ is taken by another app", [LOHotkey displayStringForKeyCode:code modifiers:mods]);
}

- (BOOL)registerShortcutKeyCode:(NSInteger)code modifiers:(NSEventModifierFlags)mods {
  __weak AppDelegate *weakSelf = self;
  return [[LOHotkey shared] registerKeyCode:code modifiers:mods handler:^{ [weakSelf lightsOut]; }];
}

- (BOOL)settingsDidChangeShortcutKeyCode:(NSInteger)keyCode modifiers:(NSEventModifierFlags)modifiers {
  NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
  if (keyCode < 0) {
    [[LOHotkey shared] unregister];
    [d removeObjectForKey:LOKeyHotkeyCode];
    [d removeObjectForKey:LOKeyHotkeyModifiers];
    return YES;
  }
  if (![self registerShortcutKeyCode:keyCode modifiers:modifiers]) {
    [self registerSavedShortcut];  // macOS refused it: keep the previous shortcut working
    return NO;
  }
  [d setInteger:keyCode forKey:LOKeyHotkeyCode];
  [d setInteger:(NSInteger)modifiers forKey:LOKeyHotkeyModifiers];
  return YES;
}

- (void)showSettings:(id)sender {
  if (!self.settings) self.settings = [[LOSettingsWindowController alloc] initWithDelegate:self];
  [self.settings present];
}

#pragma mark - Menu bar

- (void)clicked:(id)sender {
  NSEvent *e = NSApp.currentEvent;
  if (e.type == NSEventTypeRightMouseUp || (e.modifierFlags & NSEventModifierFlagControl)) {
    NSMenu *m = [NSMenu new];
    NSString *title = @"Lights Out Now";
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    if ([d objectForKey:LOKeyHotkeyCode])
      title = [title stringByAppendingFormat:@"   %@",
               [LOHotkey displayStringForKeyCode:[d integerForKey:LOKeyHotkeyCode]
                                       modifiers:(NSEventModifierFlags)[d integerForKey:LOKeyHotkeyModifiers]]];
    [m addItemWithTitle:title action:@selector(lightsOut) keyEquivalent:@""].target = self;
    [m addItemWithTitle:@"Settings…" action:@selector(showSettings:) keyEquivalent:@","].target = self;
    [m addItem:NSMenuItem.separatorItem];
    [m addItemWithTitle:@"Quit LightsOut" action:@selector(terminate:) keyEquivalent:@"q"];
    [m popUpMenuPositioningItem:nil atLocation:NSMakePoint(0, NSHeight(self.item.button.bounds) + 4)
                         inView:self.item.button];
    return;
  }
  [self lightsOut];
}

#pragma mark - Lights out

- (void)lightsOut {
  [self keyboardLightOff];
  if ([self batteryAllowsStayingAwake]) {
    [self holdAwake];
    [[LOLidMode shared] engage];  // no-op unless lid-closed mode was set up in Settings
    [self watchBattery];
  }
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

#pragma mark - Staying awake

// On battery at or below the user's cutoff (Settings, default 20%), we don't keep the Mac awake.
- (BOOL)batteryAllowsStayingAwake {
  NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
  NSInteger cutoff = [d objectForKey:LOKeyBatteryCutoff] ? [d integerForKey:LOKeyBatteryCutoff] : LODefaultBatteryCutoff;
  NSInteger percent = [LOBattery percentWhenOnBattery];
  return cutoff <= 0 || percent < 0 || percent > cutoff;
}

- (void)watchBattery {
  if (self.batteryWatch) return;
  __weak AppDelegate *weakSelf = self;
  self.batteryWatch = [LOBattery watch:^{
    if (![weakSelf batteryAllowsStayingAwake]) [weakSelf letMacSleep];
  }];
}

// Same as `caffeinate -i`: blocks idle *system* sleep but still lets the display sleep.
- (void)holdAwake {
  if (self.awake) return;
  IOPMAssertionID a = 0;
  if (IOPMAssertionCreateWithName(kIOPMAssertPreventUserIdleSystemSleep, kIOPMAssertionLevelOn,
        CFSTR("LightsOut: keep running while locked"), &a) == kIOReturnSuccess)
    self.awake = a;
}

// Hands sleep back to macOS: drop the power assertion and, if we disabled it, turn system sleep back on.
- (void)letMacSleep {
  if (self.awake) IOPMAssertionRelease(self.awake);
  self.awake = 0;
  [[LOLidMode shared] disengage];
  [LOBattery stopWatching:self.batteryWatch];
  self.batteryWatch = nil;
}

- (void)welcomeBack {
  [self stopGuard];
  [self letMacSleep];
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
