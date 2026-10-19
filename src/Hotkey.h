// A global keyboard shortcut via Carbon's RegisterEventHotKey: fires in any app and needs no Accessibility permission.
#import <Cocoa/Cocoa.h>

@interface LOHotkey : NSObject
+ (instancetype)shared;

/// Remembers the combo and registers it (replacing any previous one) unless paused.
/// keyCode is a virtual key code (kVK_*). modifiers: any of ⌘⌥⌃⇧ (NSEventModifierFlag*); other bits are ignored.
/// Returns NO if macOS refused it (e.g. another app already owns that combo); the previous combo is then unregistered.
- (BOOL)registerKeyCode:(NSInteger)keyCode modifiers:(NSEventModifierFlags)modifiers handler:(void (^)(void))handler;

/// Forgets and unregisters the combo.
- (void)unregister;

/// Temporarily unregisters (so the shortcut recorder can capture that same combo), and re-registers the remembered one.
- (void)pause;
- (void)resume;

/// e.g. "⌃⌥⌘L", "⌘F5", "⇧⌘Space". Modifier order: ⌃ ⌥ ⇧ ⌘. Letters uppercase, using the current keyboard layout.
+ (NSString *)displayStringForKeyCode:(NSInteger)keyCode modifiers:(NSEventModifierFlags)modifiers;
@end
