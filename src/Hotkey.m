#import <Carbon/Carbon.h>
#import "Hotkey.h"

static const OSType kLOHotkeySignature = 'LOut';
static const UInt32 kLOHotkeyNumber = 1;

@interface LOHotkey ()
- (void)fire;
@end

// Carbon calls this from its event loop. The handler is deferred to the next main-queue turn so it never runs inside Carbon's callback.
static OSStatus LOHotkeyPressed(EventHandlerCallRef next, EventRef event, void *userData) {
  LOHotkey *hotkey = (__bridge LOHotkey *)userData;  // the singleton lives forever, so no retain needed
  dispatch_async(dispatch_get_main_queue(), ^{ [hotkey fire]; });
  return noErr;
}

static UInt32 LOCarbonModifiers(NSEventModifierFlags flags) {
  UInt32 carbon = 0;
  if (flags & NSEventModifierFlagCommand) carbon |= cmdKey;
  if (flags & NSEventModifierFlagOption) carbon |= optionKey;
  if (flags & NSEventModifierFlagControl) carbon |= controlKey;
  if (flags & NSEventModifierFlagShift) carbon |= shiftKey;
  return carbon;
}

static NSDictionary<NSNumber *, NSString *> *LOSpecialKeyNames(void) {
  static NSDictionary<NSNumber *, NSString *> *names;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    names = @{
      @(kVK_Return): @"↩",
      @(kVK_Tab): @"⇥",
      @(kVK_Space): @"Space",
      @(kVK_Delete): @"⌫",
      @(kVK_ForwardDelete): @"⌦",
      @(kVK_Escape): @"⎋",
      @(kVK_LeftArrow): @"←",
      @(kVK_RightArrow): @"→",
      @(kVK_UpArrow): @"↑",
      @(kVK_DownArrow): @"↓",
      @(kVK_Home): @"↖",
      @(kVK_End): @"↘",
      @(kVK_PageUp): @"⇞",
      @(kVK_PageDown): @"⇟",
      @(kVK_F1): @"F1", @(kVK_F2): @"F2", @(kVK_F3): @"F3", @(kVK_F4): @"F4", @(kVK_F5): @"F5",
      @(kVK_F6): @"F6", @(kVK_F7): @"F7", @(kVK_F8): @"F8", @(kVK_F9): @"F9", @(kVK_F10): @"F10",
      @(kVK_F11): @"F11", @(kVK_F12): @"F12", @(kVK_F13): @"F13", @(kVK_F14): @"F14", @(kVK_F15): @"F15",
      @(kVK_F16): @"F16", @(kVK_F17): @"F17", @(kVK_F18): @"F18", @(kVK_F19): @"F19", @(kVK_F20): @"F20",
    };
  });
  return names;
}

// Looks up the character a key types in the current layout (e.g. "L" on QWERTY, "K" on AZERTY). Returns nil if it has none.
static NSString *LOKeyCharacter(NSInteger keyCode) {
  TISInputSourceRef source = TISCopyCurrentKeyboardLayoutInputSource();
  CFDataRef layoutData = source ? TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) : NULL;
  if (!layoutData) {  // some input methods (e.g. CJK) have no Unicode layout; fall back to plain ASCII
    if (source) CFRelease(source);
    source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource();
    layoutData = source ? TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) : NULL;
  }
  NSString *result = nil;
  if (layoutData) {
    const UCKeyboardLayout *layout = (const UCKeyboardLayout *)CFDataGetBytePtr(layoutData);
    UniChar chars[4];
    UniCharCount length = 0;
    UInt32 deadKeyState = 0;
    OSStatus status = UCKeyTranslate(layout, (UInt16)keyCode, kUCKeyActionDisplay, 0, LMGetKbdType(),
                                     kUCKeyTranslateNoDeadKeysMask, &deadKeyState, 4, &length, chars);
    if (status == noErr && length > 0) {
      result = [[NSString stringWithCharacters:chars length:length] uppercaseString];
    }
  }
  if (source) CFRelease(source);  // Copy* functions return a retained reference
  return result;
}

@implementation LOHotkey {
  EventHotKeyRef _hotKeyRef;      // NULL while not registered with macOS
  EventHandlerRef _eventHandler;  // installed once, on the first register
  NSInteger _keyCode;             // -1 = no combo
  NSEventModifierFlags _modifiers;
  void (^_handler)(void);
  BOOL _paused;
}

+ (instancetype)shared {
  static LOHotkey *shared;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ shared = [[LOHotkey alloc] init]; });
  return shared;
}

- (instancetype)init {
  self = [super init];
  if (self) _keyCode = -1;
  return self;
}

- (BOOL)registerKeyCode:(NSInteger)keyCode modifiers:(NSEventModifierFlags)modifiers handler:(void (^)(void))handler {
  [self unregisterRef];  // replace the old registration, whatever happens next
  if (keyCode < 0) {
    [self unregister];
    return YES;
  }
  _keyCode = keyCode;
  _modifiers = modifiers;
  _handler = [handler copy];
  if (_paused) return YES;  // resume() registers it

  OSStatus status = [self registerStoredCombo];
  if (status != noErr) {
    _keyCode = -1;  // macOS refused it (usually another app owns the combo); forget it
    return NO;
  }
  return YES;
}

- (void)unregister {
  _keyCode = -1;
  _modifiers = 0;
  _handler = nil;
  [self unregisterRef];
}

- (void)pause {
  _paused = YES;
  [self unregisterRef];
}

- (void)resume {
  if (!_paused) return;
  _paused = NO;
  if (_keyCode >= 0 && !_hotKeyRef) {
    [self registerStoredCombo];  // on failure the combo is kept but stays inactive
  }
}

+ (NSString *)displayStringForKeyCode:(NSInteger)keyCode modifiers:(NSEventModifierFlags)modifiers {
  NSMutableString *text = [NSMutableString string];
  if (modifiers & NSEventModifierFlagControl) [text appendString:@"⌃"];
  if (modifiers & NSEventModifierFlagOption) [text appendString:@"⌥"];
  if (modifiers & NSEventModifierFlagShift) [text appendString:@"⇧"];
  if (modifiers & NSEventModifierFlagCommand) [text appendString:@"⌘"];
  NSString *name = LOSpecialKeyNames()[@(keyCode)] ?: LOKeyCharacter(keyCode)
                   ?: [NSString stringWithFormat:@"Key %ld", (long)keyCode];
  [text appendString:name];
  return text;
}

#pragma mark - Private

// Caller must have unregistered first, so this never double-registers.
- (OSStatus)registerStoredCombo {
  if (!_eventHandler) {
    EventTypeSpec type = { kEventClassKeyboard, kEventHotKeyPressed };
    OSStatus status = InstallEventHandler(GetApplicationEventTarget(), LOHotkeyPressed, 1, &type,
                                          (__bridge void *)self, &_eventHandler);
    if (status != noErr) return status;
  }
  EventHotKeyID hotKeyID = { kLOHotkeySignature, kLOHotkeyNumber };
  EventHotKeyRef ref = NULL;
  OSStatus status = RegisterEventHotKey((UInt32)_keyCode, LOCarbonModifiers(_modifiers), hotKeyID,
                                        GetApplicationEventTarget(), 0, &ref);
  _hotKeyRef = ref;
  return status;
}

- (void)unregisterRef {
  if (_hotKeyRef) {
    UnregisterEventHotKey(_hotKeyRef);
    _hotKeyRef = NULL;
  }
}

- (void)fire {
  if (_handler) _handler();
}

@end
