// The Settings window: keyboard shortcut, lid-closed mode, keep-awake apps, battery cutoff, start at login.
#import <Cocoa/Cocoa.h>

@protocol LOSettingsDelegate <NSObject>
/// The user recorded (keyCode >= 0) or cleared (keyCode -1) the shortcut. Return NO if macOS refused it.
- (BOOL)settingsDidChangeShortcutKeyCode:(NSInteger)keyCode modifiers:(NSEventModifierFlags)modifiers;
- (BOOL)startsAtLogin;
- (void)setStartsAtLogin:(BOOL)on;
@end

@interface LOSettingsWindowController : NSWindowController
- (instancetype)initWithDelegate:(id<LOSettingsDelegate>)delegate;
/// Refreshes every control from current state, centers on first show, and brings the window to the front.
- (void)present;
@end
