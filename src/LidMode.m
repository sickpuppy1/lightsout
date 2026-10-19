#import "LidMode.h"
#import "Keys.h"

NSString *const LOSudoersPath = @"/etc/sudoers.d/lightsout";

// Runs a tool directly (no shell). Returns its exit status, or -1 if it could not start.
static int LORun(NSString *path, NSArray<NSString *> *args, NSString **output) {
  NSTask *task = [[NSTask alloc] init];
  task.executableURL = [NSURL fileURLWithPath:path];  // the SDK marks launchPath for deprecation
  task.arguments = args;
  NSPipe *pipe = [NSPipe pipe];
  task.standardOutput = pipe;
  task.standardError = NSFileHandle.fileHandleWithNullDevice;
  @try {
    [task launch];
  } @catch (NSException *e) {
    return -1;
  }
  NSData *data = [pipe.fileHandleForReading readDataToEndOfFile];  // read before waiting so a full pipe cannot hang us
  [task waitUntilExit];
  if (output) *output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
  return task.terminationStatus;
}

// Runs an AppleScript source (which may show the admin password dialog). Same error contract as install:.
static BOOL LORunAdmin(NSString *source, NSString *fallback, NSString **errorMessage) {
  NSDictionary *info = nil;
  NSAppleScript *script = [[NSAppleScript alloc] initWithSource:source];
  if ([script executeAndReturnError:&info]) return YES;
  NSString *message = nil;
  if ([info[NSAppleScriptErrorNumber] integerValue] != -128) {  // -128 = user pressed Cancel
    message = info[NSAppleScriptErrorMessage] ?: fallback;
  }
  if (errorMessage) *errorMessage = message;
  return NO;
}

// Escapes a string so it can sit inside an AppleScript "..." literal.
static NSString *LOAppleScriptEscape(NSString *s) {
  s = [s stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"];
  return [s stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
}

// Splits a line on any whitespace/tabs, dropping empty pieces.
static NSArray<NSString *> *LOTokens(NSString *line) {
  NSMutableArray *out = [NSMutableArray array];
  for (NSString *part in [line componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet]) {
    if (part.length) [out addObject:part];
  }
  return out;
}

static void LOSetEngaged(BOOL engaged) {
  NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
  [d setBool:engaged forKey:LOKeyLidEngaged];
  [d synchronize];  // write now, so a crash still leaves the flag on disk for the next launch to clean up
}

@interface LOLidMode ()
- (BOOL)sleepDisabledNow;
@end

@implementation LOLidMode

+ (instancetype)shared {
  static LOLidMode *instance;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ instance = [[LOLidMode alloc] init]; });
  return instance;
}

- (BOOL)isInstalled {
  return [NSFileManager.defaultManager fileExistsAtPath:LOSudoersPath];
}

- (BOOL)engaged {
  return [NSUserDefaults.standardUserDefaults boolForKey:LOKeyLidEngaged];
}

- (BOOL)sleepDisabledNow {
  NSString *out = nil;
  if (LORun(@"/usr/bin/pmset", @[@"-g"], &out) != 0 || !out) return NO;
  for (NSString *line in [out componentsSeparatedByString:@"\n"]) {
    NSArray<NSString *> *tokens = LOTokens(line);
    if (tokens.count >= 2 && [tokens[0] isEqualToString:@"SleepDisabled"]) {
      return [tokens[1] isEqualToString:@"1"];
    }
  }
  return NO;
}

- (BOOL)install:(NSString **)errorMessage {
  NSString *user = NSUserName();
  NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"^[A-Za-z0-9._-]+$" options:0 error:NULL];
  if ([re numberOfMatchesInString:user options:0 range:NSMakeRange(0, user.length)] == 0) {
    if (errorMessage) *errorMessage = [NSString stringWithFormat:@"Refusing to write a sudoers rule for the user name \"%@\".", user];
    return NO;
  }

  // %1$@ is the user name; the sudoers line must name exactly the two pmset commands engage/disengage use.
  NSString *rule = [NSString stringWithFormat:
      @"# Installed by LightsOut (https://github.com/sickpuppy1/lightsout).\n"
      @"# Lets %1$@ turn system sleep off and on without a password. Nothing else.\n"
      @"%1$@ ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0\n", user];

  NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:
      [NSString stringWithFormat:@"lightsout-sudoers-%@", NSUUID.UUID.UUIDString]];
  NSError *err = nil;
  if (![rule writeToFile:tmp atomically:NO encoding:NSUTF8StringEncoding error:&err]) {
    if (errorMessage) *errorMessage = [NSString stringWithFormat:@"Could not write a temporary file: %@", err.localizedDescription];
    return NO;
  }

  // visudo -cf checks the syntax first, so a bad rule never reaches /etc/sudoers.d.
  NSString *q = LOAppleScriptEscape(tmp);
  NSString *source = [NSString stringWithFormat:
      @"do shell script \"/bin/mkdir -p /etc/sudoers.d && /usr/sbin/visudo -cf \" & quoted form of \"%@\""
      @" & \" && /usr/bin/install -m 0440 -o root -g wheel \" & quoted form of \"%@\" & \" %@\""
      @" with prompt \"LightsOut needs your password once so your Mac can stay awake with the lid closed.\""
      @" with administrator privileges", q, q, LOSudoersPath];
  BOOL ok = LORunAdmin(source, @"Could not install the lid-closed permission.", errorMessage);
  [NSFileManager.defaultManager removeItemAtPath:tmp error:NULL];
  if (!ok) return NO;

  // Check that sudo actually reads the rule; some setups turn off /etc/sudoers.d.
  if (LORun(@"/usr/bin/sudo", @[@"-n", @"-l", @"/usr/bin/pmset", @"-a", @"disablesleep", @"0"], NULL) == 0) return YES;
  if (errorMessage) *errorMessage = @"The permission was installed, but sudo on this Mac does not read /etc/sudoers.d. Lid-closed mode can't be used.";
  return NO;
}

- (BOOL)uninstall:(NSString **)errorMessage {
  [self disengage];
  NSString *source = [NSString stringWithFormat:
      @"do shell script \"/bin/rm -f %@\""
      @" with prompt \"LightsOut needs your password to remove its lid-closed permission.\""
      @" with administrator privileges", LOSudoersPath];
  return LORunAdmin(source, @"Could not remove the lid-closed permission.", errorMessage);
}

- (BOOL)engage {
  if (!self.isInstalled) return NO;
  // The user turned sleep off by hand. Leave it alone and do not claim it as ours.
  if ([self sleepDisabledNow] && !self.engaged) return YES;
  if (LORun(@"/usr/bin/sudo", @[@"-n", @"/usr/bin/pmset", @"-a", @"disablesleep", @"1"], NULL) != 0) return NO;
  LOSetEngaged(YES);
  return YES;
}

- (void)disengage {
  if (!self.engaged) return;
  if (LORun(@"/usr/bin/sudo", @[@"-n", @"/usr/bin/pmset", @"-a", @"disablesleep", @"0"], NULL) == 0) {
    LOSetEngaged(NO);
    return;
  }
  // The sudoers rule is probably gone. Ask for the password instead, so sleep does not stay off.
  NSString *err = nil;
  NSString *source = @"do shell script \"/usr/bin/pmset -a disablesleep 0\""
                     @" with prompt \"LightsOut needs your password to turn sleep back on.\""
                     @" with administrator privileges";
  if (LORunAdmin(source, @"Could not turn sleep back on.", &err)) {
    LOSetEngaged(NO);
  } else {
    // Flag stays set, so the next launch retries.
    NSLog(@"LightsOut: could not re-enable sleep (%@). Will retry at next launch.", err ?: @"cancelled");
  }
}

@end
