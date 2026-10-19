// A button that shows a keyboard shortcut. Click it, press a combo, and it records it.
#import <Cocoa/Cocoa.h>

@interface LOShortcutRecorder : NSButton

/// Current shortcut. keyCode -1 = none (button shows "Record Shortcut").
@property (nonatomic) NSInteger keyCode;
@property (nonatomic) NSEventModifierFlags modifiers;

/// Called after the user records or clears a shortcut (keyCode -1 = cleared).
/// Return NO to reject it (e.g. macOS refused the combo): the recorder beeps and reverts to the previous value.
@property (copy) BOOL (^onChange)(NSInteger keyCode, NSEventModifierFlags modifiers);

@end
