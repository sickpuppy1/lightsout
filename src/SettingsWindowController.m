#import "SettingsWindowController.h"
#import "Keys.h"
#import "LidMode.h"
#import "Processes.h"
#import "ShortcutRecorder.h"

static NSString *const kGitHubURL = @"https://github.com/sickpuppy1/lightsout";

@interface LOSettingsWindowController () <NSMenuDelegate>
@property (weak) id<LOSettingsDelegate> delegate;
@property (strong) LOShortcutRecorder *recorder;
@property (strong) NSButton *lidBox;
@property (strong) NSPopUpButton *awakePopup;
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

  // Row 3: keep awake until unlock, or only while picked apps / terminal commands run.
  // A pull-down: item 0 is the button's title, the rest is rebuilt from what's running each time it opens.
  self.awakePopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:YES];
  self.awakePopup.menu.delegate = self;
  self.awakePopup.autoenablesItems = NO;  // so the section headers below stay disabled labels
  self.awakePopup.translatesAutoresizingMaskIntoConstraints = NO;
  [self.awakePopup.widthAnchor constraintLessThanOrEqualToConstant:230].active = YES;  // long picks truncate
  ((NSPopUpButtonCell *)self.awakePopup.cell).lineBreakMode = NSLineBreakByTruncatingTail;
  NSStackView *awakeRow = [self rowWithViews:@[[NSTextField labelWithString:@"Keep the Mac awake:"], self.awakePopup]];
  NSStackView *awakeGroup = [self groupWithRow:awakeRow
                                          help:@"Pick apps or terminal commands to let the Mac sleep "
                                               @"as soon as they have all quit."];

  // Row 4: battery cutoff.
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

  // Row 5: start at login.
  self.loginBox = [NSButton checkboxWithTitle:@"Start LightsOut at login"
                                       target:self
                                       action:@selector(loginToggled:)];
  NSStackView *loginGroup = [self groupWithRow:self.loginBox help:nil];

  // Row 6: footer with the GitHub link and version.
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

  NSStackView *root = [NSStackView stackViewWithViews:@[shortcutGroup, lidGroup, awakeGroup, cutoffGroup, loginGroup, footer]];
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

  [self refreshAwakeTitle];

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

#pragma mark - Keep-awake menu

- (NSArray<NSString *> *)picked:(NSString *)key {
  return [NSUserDefaults.standardUserDefaults stringArrayForKey:key] ?: @[];
}

static NSString *appName(NSString *bundleID) {
  NSRunningApplication *app = [NSRunningApplication runningApplicationsWithBundleIdentifier:bundleID].firstObject;
  if (app.localizedName) return app.localizedName;
  NSURL *url = [NSWorkspace.sharedWorkspace URLForApplicationWithBundleIdentifier:bundleID];
  return url ? [NSFileManager.defaultManager displayNameAtPath:url.path].stringByDeletingPathExtension : bundleID;
}

- (void)refreshAwakeTitle {
  NSMutableArray<NSString *> *names = [NSMutableArray array];
  for (NSString *bundleID in [self picked:LOKeyAwakeApps]) [names addObject:appName(bundleID)];
  [names addObjectsFromArray:[self picked:LOKeyAwakeCommands]];
  NSString *title = names.count ? [@"While running: " stringByAppendingString:[names componentsJoinedByString:@", "]]
                                : @"Until I unlock";
  if (!self.awakePopup.numberOfItems) [self.awakePopup addItemWithTitle:@""];
  [self.awakePopup itemAtIndex:0].title = title;
}

- (void)menuNeedsUpdate:(NSMenu *)menu {
  NSArray<NSString *> *apps = [self picked:LOKeyAwakeApps], *commands = [self picked:LOKeyAwakeCommands];
  NSMenuItem *title = [menu itemAtIndex:0];
  [menu removeAllItems];
  [menu addItem:title];

  NSMenuItem *unlock = [menu addItemWithTitle:@"Until I unlock" action:@selector(awakeUntilUnlock:) keyEquivalent:@""];
  unlock.target = self;
  unlock.state = (apps.count || commands.count) ? NSControlStateValueOff : NSControlStateValueOn;

  NSMutableArray<NSString *> *runningApps = [NSMutableArray array];
  for (NSRunningApplication *app in [LOProcesses regularApps]) [runningApps addObject:app.bundleIdentifier];
  [self addSection:@"Apps" running:runningApps picked:apps name:^(NSString *b) { return appName(b); }
            action:@selector(toggleApp:) toMenu:menu];
  [self addSection:@"Terminal commands" running:[LOProcesses terminalCommands] picked:commands
              name:^(NSString *c) { return c; } action:@selector(toggleCommand:) toMenu:menu];
}

// A header and one tick-able item per running value; picked ones that aren't running stay listed so they can be unticked.
- (void)addSection:(NSString *)header running:(NSArray<NSString *> *)running picked:(NSArray<NSString *> *)picked
              name:(NSString * (^)(NSString *))name action:(SEL)action toMenu:(NSMenu *)menu {
  [menu addItem:NSMenuItem.separatorItem];
  [menu addItemWithTitle:header action:nil keyEquivalent:@""].enabled = NO;
  NSMutableArray<NSString *> *values = [running mutableCopy];
  for (NSString *v in picked) if (![values containsObject:v]) [values addObject:v];
  if (!values.count) {
    NSMenuItem *none = [menu addItemWithTitle:@"None running" action:nil keyEquivalent:@""];
    none.enabled = NO;
    none.indentationLevel = 1;
  }
  for (NSString *v in values) {
    NSString *title = [running containsObject:v] ? name(v) : [name(v) stringByAppendingString:@" (not running)"];
    NSMenuItem *item = [menu addItemWithTitle:title action:action keyEquivalent:@""];
    item.target = self;
    item.representedObject = v;
    item.indentationLevel = 1;
    item.state = [picked containsObject:v] ? NSControlStateValueOn : NSControlStateValueOff;
  }
}

- (void)awakeUntilUnlock:(id)sender {
  [NSUserDefaults.standardUserDefaults removeObjectForKey:LOKeyAwakeApps];
  [NSUserDefaults.standardUserDefaults removeObjectForKey:LOKeyAwakeCommands];
  [self refreshAwakeTitle];
}

- (void)toggleApp:(NSMenuItem *)item { [self toggle:item.representedObject inList:LOKeyAwakeApps]; }

- (void)toggleCommand:(NSMenuItem *)item { [self toggle:item.representedObject inList:LOKeyAwakeCommands]; }

- (void)toggle:(NSString *)value inList:(NSString *)key {
  NSMutableArray<NSString *> *list = [[self picked:key] mutableCopy];
  if ([list containsObject:value]) [list removeObject:value];
  else [list addObject:value];
  [NSUserDefaults.standardUserDefaults setObject:list forKey:key];
  [self refreshAwakeTitle];
}

- (void)openGitHub:(id)sender {
  [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:kGitHubURL]];
}

@end
