// Lid-closed mode: while LightsOut has the Mac locked, system sleep is fully disabled (`pmset -a disablesleep 1`),
// so closing the lid does not sleep the Mac. That needs root, granted ONCE through a narrow sudoers rule that only
// allows `/usr/bin/pmset -a disablesleep 1` and `/usr/bin/pmset -a disablesleep 0` without a password.
#import <Foundation/Foundation.h>

extern NSString *const LOSudoersPath;  // @"/etc/sudoers.d/lightsout"

@interface LOLidMode : NSObject
+ (instancetype)shared;

/// YES if the sudoers rule file exists.
@property (readonly) BOOL isInstalled;

/// YES while LightsOut itself has sleep disabled (persisted in NSUserDefaults LOKeyLidEngaged, survives crashes/reboots).
@property (readonly) BOOL engaged;

/// Shows the standard macOS admin password dialog and installs the sudoers rule.
/// Returns YES on success. On failure returns NO and sets *errorMessage (nil if the user just pressed Cancel).
- (BOOL)install:(NSString **)errorMessage;

/// Re-enables sleep if we disabled it, then removes the rule (admin password dialog). Same return contract as install:.
- (BOOL)uninstall:(NSString **)errorMessage;

/// Disables system sleep, lid close included. Silent (uses `sudo -n`). Returns YES if sleep is now disabled.
/// If the user had already disabled sleep themselves, does nothing and does not mark it as ours.
- (BOOL)engage;

/// Re-enables sleep if and only if we disabled it. Silent, idempotent, safe to call any time (e.g. at launch to clean up
/// after a crash or reboot).
- (void)disengage;

@end
