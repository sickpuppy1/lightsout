// What's running: apps and terminal commands, for "keep the Mac awake only while these run".
#import <Cocoa/Cocoa.h>

@interface LOProcesses : NSObject

/// Apps with a Dock icon that are running now, sorted by name.
+ (NSArray<NSRunningApplication *> *)regularApps;

/// Names of commands running in a terminal (claude, npm, make, ...), sorted, shells left out.
+ (NSArray<NSString *> *)terminalCommands;

/// YES if any of these apps (bundle IDs) or commands (names as terminalCommands gives them) is running.
+ (BOOL)anyRunningApps:(NSArray<NSString *> *)bundleIDs commands:(NSArray<NSString *> *)names;

@end
