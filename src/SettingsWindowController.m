#import "SettingsWindowController.h"
#import "Keys.h"
#import "LidMode.h"
#import "ShortcutRecorder.h"

static NSString *const kGitHubURL = @"https://github.com/sickpuppy1/lightsout";

@interface LOSettingsWindowController ()
@property (weak) id<LOSettingsDelegate> delegate;
@property (strong) LOShortcutRecorder *recorder;
@property (strong) NSButton *lidBox;
@property (strong) NSPopUpButton *cutoffPopup;
@property (strong) NSButton *loginBox;
@property (strong) NSStackView *rootStack;
@property (assign) BOOL didCenter;
@end

@implementation LOSettingsWindowController

- (instancetype)initWithDelegate:(id<LOSettingsDelegate>)delegate {
  NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 420, 300)
                                                 styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                                                   backing:NSBackingStoreBuffered
                                                     defer:NO];
  window.title = @"LightsOut Settings";
  window.releasedWhenClosed = NO;

  self = [super initWithWindow:window];
  if (self) {
    _delegate = delegate;
    [self buildContent];
    [self refreshControls];
    [window setContentSize:self.rootStack.fittingSize];
  }
  return self;
}

- (void)present {
  [self refreshControls];
  if (!self.didCenter) {
    [self.window center];
    self.didCenter = YES;
  }
  [NSApp activateIgnoringOtherApps:YES];
  [self.window makeKeyAndOrderFront:nil];
}

#pragma mark - Building the UI

- (void)buildContent {
  NSView *content = self.window.contentView;

  // Row 1: shortcut recorder.
  self.recorder = [[LOShortcutRecorder alloc] initWithFrame:NSZeroRect];
  self.recorder.translatesAutoresizingMaskIntoConstraints = NO;
  [self.recorder.widthAnchor constraintEqualToConstant:170].active = YES;
  // Weak copy so the block does not keep the delegate alive.
  __weak id<LOSettingsDelegate> weakDelegate = self.delegate;
  self.recorder.onChange = ^BOOL(NSInteger keyCode, NSEventModifierFlags modifiers) {
    if (!weakDelegate) return NO;
    return [weakDelegate settingsDidChangeShortcutKeyCode:keyCode modifiers:modifiers];
  };
  NSStackView *shortcutRow = [self rowWithViews:@[[NSTextField labelWithString:@"Lights-out shortcut:"], self.recorder]];
  NSStackView *shortcutGroup = [self groupWithRow:shortcutRow
                                             help:@"Click, then press a key combination that includes ⌘ or ⌃. "
                                                  @"Delete clears it, Esc cancels."];

  // Row 2: lid-closed mode.
  self.lidBox = [NSButton checkboxWithTitle:@"Keep running with the lid closed"
                                     target:self
                                     action:@selector(lidModeToggled:)];
  NSStackView *lidGroup = [self groupWithRow:self.lidBox
                                        help:@"Asks for your admin password once. "
                                             @"Sleep is turned back on the moment you unlock."];

  // Row 3: battery cutoff.
  self.cutoffPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
  NSArray<NSString *> *titles = @[@"Never", @"10%", @"20%", @"30%", @"50%"];
  const NSInteger tags[] = {0, 10, 20, 30, 50};
  for (NSUInteger i = 0; i < titles.count; i++) {
    [self.cutoffPopup addItemWithTitle:titles[i]];
    self.cutoffPopup.lastItem.tag = tags[i];
  }
  self.cutoffPopup.target = self;
  self.cutoffPopup.action = @selector(cutoffChanged:);
  NSStackView *cutoffRow = [self rowWithViews:@[[NSTextField labelWithString:@"On battery, let the Mac sleep at:"],
                                                self.cutoffPopup]];
  NSStackView *cutoffGroup = [self groupWithRow:cutoffRow
                                           help:@"A safety net while LightsOut keeps your Mac awake: "
                                                @"below this charge, normal sleep comes back."];

  // Row 4: start at login.
  self.loginBox = [NSButton checkboxWithTitle:@"Start LightsOut at login"
                                       target:self
                                       action:@selector(loginToggled:)];
  NSStackView *loginGroup = [self groupWithRow:self.loginBox help:nil];

  // Row 5: footer with the GitHub link and version.
  NSButton *github = [NSButton buttonWithTitle:@"LightsOut on GitHub" target:self action:@selector(openGitHub:)];
  github.bordered = NO;
  github.attributedTitle = [[NSAttributedString alloc] initWithString:github.title attributes:@{
    NSForegroundColorAttributeName: NSColor.linkColor,
    NSFontAttributeName: [NSFont systemFontOfSize:NSFont.smallSystemFontSize],
  }];
  NSString *version = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"dev";
  NSTextField *versionLabel = [NSTextField labelWithString:[NSString stringWithFormat:@"Version %@", version]];
  versionLabel.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
  versionLabel.textColor = NSColor.secondaryLabelColor;
  NSStackView *footer = [self rowWithViews:@[github, versionLabel]];

  NSStackView *root = [NSStackView stackViewWithViews:@[shortcutGroup, lidGroup, cutoffGroup, loginGroup, footer]];
  root.orientation = NSUserInterfaceLayoutOrientationVertical;
  root.alignment = NSLayoutAttributeLeading;
  root.spacing = 16;
  root.edgeInsets = NSEdgeInsetsMake(20, 20, 20, 20);
  root.translatesAutoresizingMaskIntoConstraints = NO;
  [content addSubview:root];
  [NSLayoutConstraint activateConstraints:@[
    [root.topAnchor constraintEqualToAnchor:content.topAnchor],
    [root.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
    [root.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
    [root.bottomAnchor constraintEqualToAnchor:content.bottomAnchor],
    [root.widthAnchor constraintEqualToConstant:420],  // fixed width: help text wraps at 380 inside 20pt insets
  ]];
  self.rootStack = root;
}

// A horizontal row of views, vertically centered.
- (NSStackView *)rowWithViews:(NSArray<NSView *> *)views {
  NSStackView *row = [NSStackView stackViewWithViews:views];
  row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
  row.alignment = NSLayoutAttributeCenterY;
  row.spacing = 8;
  return row;
}

// A control (or row) with its help text underneath. Help is optional.
- (NSStackView *)groupWithRow:(NSView *)control help:(NSString *)help {
  NSMutableArray<NSView *> *views = [NSMutableArray arrayWithObject:control];
  if (help) {
    NSTextField *label = [NSTextField wrappingLabelWithString:help];
    label.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    label.textColor = NSColor.secondaryLabelColor;
    label.preferredMaxLayoutWidth = 380;
    [views addObject:label];
  }
  NSStackView *group = [NSStackView stackViewWithViews:views];
  group.orientation = NSUserInterfaceLayoutOrientationVertical;
  group.alignment = NSLayoutAttributeLeading;
  group.spacing = 4;
  return group;
}

#pragma mark - Reading state

// Pulls every control's value from NSUserDefaults, the lid-mode state, and the delegate.
- (void)refreshControls {
  NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;

  NSInteger keyCode = [defaults objectForKey:LOKeyHotkeyCode] ? [defaults integerForKey:LOKeyHotkeyCode] : -1;
  self.recorder.keyCode = keyCode;
  self.recorder.modifiers = (NSEventModifierFlags)[defaults integerForKey:LOKeyHotkeyModifiers];

  self.lidBox.state = [[LOLidMode shared] isInstalled] ? NSControlStateValueOn : NSControlStateValueOff;

  NSInteger cutoff = [defaults objectForKey:LOKeyBatteryCutoff] ? [defaults integerForKey:LOKeyBatteryCutoff]
                                                                : LODefaultBatteryCutoff;
  [self.cutoffPopup selectItemWithTag:cutoff];

  self.loginBox.state = [self.delegate startsAtLogin] ? NSControlStateValueOn : NSControlStateValueOff;
}

#pragma mark - Actions

- (void)lidModeToggled:(NSButton *)sender {
  NSString *error = nil;
  if (sender.state == NSControlStateValueOn) {
    [[LOLidMode shared] install:&error];
  } else {
    [[LOLidMode shared] uninstall:&error];
  }
  // Show the real state, not the click: the user may have cancelled the password dialog.
  self.lidBox.state = [[LOLidMode shared] isInstalled] ? NSControlStateValueOn : NSControlStateValueOff;

  if (error) {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.alertStyle = NSAlertStyleWarning;
    alert.messageText = @"Lid-closed mode";
    alert.informativeText = error;
    [alert beginSheetModalForWindow:self.window completionHandler:nil];
  }
}

- (void)cutoffChanged:(NSPopUpButton *)sender {
  [NSUserDefaults.standardUserDefaults setInteger:sender.selectedTag forKey:LOKeyBatteryCutoff];
}

- (void)loginToggled:(NSButton *)sender {
  [self.delegate setStartsAtLogin:(sender.state == NSControlStateValueOn)];
}

- (void)openGitHub:(id)sender {
  [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:kGitHubURL]];
}

@end
