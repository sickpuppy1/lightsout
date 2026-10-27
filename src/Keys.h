// NSUserDefaults keys shared across LightsOut's files.
#import <Foundation/Foundation.h>

static NSString *const LOKeyHotkeyCode = @"hotkeyKeyCode";            // NSInteger, -1 or absent = no shortcut
static NSString *const LOKeyHotkeyModifiers = @"hotkeyModifiers";     // NSEventModifierFlags (⌘⌥⌃⇧ only)
static NSString *const LOKeyBatteryCutoff = @"batteryCutoffPercent";  // NSInteger, 0 = never; default 20
static NSString *const LOKeyLidEngaged = @"lidModeEngaged";           // BOOL, YES while WE have sleep disabled
static NSString *const LOKeyDidSetUp = @"didSetUp";                   // BOOL, first-run done
static NSString *const LOKeyAwakeApps = @"awakeAppBundleIDs";         // [NSString]; with commands empty = until unlock
static NSString *const LOKeyAwakeCommands = @"awakeCommandNames";     // [NSString], terminal command names

static const NSInteger LODefaultBatteryCutoff = 20;
