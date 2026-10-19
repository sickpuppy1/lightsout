#import <Carbon/Carbon.h>  // kVK_* key codes
#import "ShortcutRecorder.h"
#import "Hotkey.h"

static const NSEventModifierFlags kLOShortcutFlags = NSEventModifierFlagCommand | NSEventModifierFlagOption
                                                   | NSEventModifierFlagControl | NSEventModifierFlagShift;

// F1 alone is a valid shortcut; other keys need Command or Control so they can't clash with typing.
static const NSInteger kLOFunctionKeys[] = {
  kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
  kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
};

static BOOL LOIsFunctionKey(NSInteger keyCode) {
  for (size_t i = 0; i < sizeof(kLOFunctionKeys) / sizeof(kLOFunctionKeys[0]); i++) {
    if (kLOFunctionKeys[i] == keyCode) return YES;
  }
  return NO;
}

@interface LOShortcutRecorder ()
@property (nonatomic) BOOL recording;
@property (strong) id monitor;  // NSEvent local monitor token, set only while recording
@end

@implementation LOShortcutRecorder

- (instancetype)initWithFrame:(NSRect)frameRect {
  self = [super initWithFrame:frameRect];
  if (self) [self setup];
  return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder {
  self = [super initWithCoder:coder];
  if (self) [self setup];
  return self;
}

- (void)setup {
  self.bezelStyle = NSBezelStyleRounded;
  self.target = self;
  self.action = @selector(toggleRecording:);
  self.keyEquivalent = @"";
  self.keyCode = -1;
}

- (void)setKeyCode:(NSInteger)keyCode {
  _keyCode = keyCode;
  [self updateTitle];
}

- (void)setModifiers:(NSEventModifierFlags)modifiers {
  _modifiers = modifiers;
  [self updateTitle];
}

- (void)updateTitle {
  if (self.recording) {
    self.title = @"Type shortcut…";
  } else if (_keyCode < 0) {
    self.title = @"Record Shortcut";
  } else {
    self.title = [LOHotkey displayStringForKeyCode:_keyCode modifiers:_modifiers];
  }
}

- (void)toggleRecording:(id)sender {
  if (self.recording) {
    [self stopRecording];
  } else {
    [self startRecording];
  }
}

- (void)startRecording {
  self.recording = YES;
  [[LOHotkey shared] pause];  // so pressing the current combo doesn't fire it while we record
  __weak LOShortcutRecorder *weakSelf = self;
  self.monitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown handler:^NSEvent *(NSEvent *event) {
    [weakSelf handleKeyEvent:event];
    return nil;  // swallow the key so it doesn't reach a text field or menu
  }];
  [self updateTitle];
}

// Also used for cancel. Resumes the hotkey, so it must run before onChange registers a new combo.
- (void)stopRecording {
  if (!self.recording) return;
  self.recording = NO;
  if (self.monitor) [NSEvent removeMonitor:self.monitor];
  self.monitor = nil;
  [[LOHotkey shared] resume];
  [self updateTitle];
}

- (void)handleKeyEvent:(NSEvent *)event {
  NSEventModifierFlags flags = event.modifierFlags & kLOShortcutFlags;
  NSInteger keyCode = event.keyCode;

  if (keyCode == kVK_Escape && flags == 0) {
    [self stopRecording];
    return;
  }
  if ((keyCode == kVK_Delete || keyCode == kVK_ForwardDelete) && flags == 0) {
    [self proposeKeyCode:-1 modifiers:0];  // clears the shortcut
    return;
  }
  BOOL hasCommandOrControl = (flags & (NSEventModifierFlagCommand | NSEventModifierFlagControl)) != 0;
  if (!hasCommandOrControl && !LOIsFunctionKey(keyCode)) {
    NSBeep();
    return;
  }
  [self proposeKeyCode:keyCode modifiers:flags];
}

- (void)proposeKeyCode:(NSInteger)keyCode modifiers:(NSEventModifierFlags)modifiers {
  [self stopRecording];
  BOOL (^change)(NSInteger, NSEventModifierFlags) = self.onChange;
  if (change && !change(keyCode, modifiers)) {
    NSBeep();  // stopRecording already restored the old title
    return;
  }
  self.modifiers = modifiers;
  self.keyCode = keyCode;
}

#pragma mark - Window tracking

- (void)viewDidMoveToWindow {
  [super viewDidMoveToWindow];
  [NSNotificationCenter.defaultCenter removeObserver:self name:NSWindowDidResignKeyNotification object:nil];
  if (self.window) {
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(windowDidResignKey:)
                                               name:NSWindowDidResignKeyNotification object:self.window];
  } else {
    [self stopRecording];  // removed from its window mid-recording: don't leave the monitor running
  }
}

- (void)windowDidResignKey:(NSNotification *)note {
  if (note.object == self.window) [self stopRecording];
}

- (void)dealloc {
  if (_recording) [[LOHotkey shared] resume];
  if (_monitor) [NSEvent removeMonitor:_monitor];
  [NSNotificationCenter.defaultCenter removeObserver:self];
}

@end
