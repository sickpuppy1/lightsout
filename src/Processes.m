#import "Processes.h"
#include <libproc.h>
#include <sys/sysctl.h>

// The name a terminal shows for a process: argv[0]'s first word, without its path or a login shell's "-".
// Not the executable's file name: Claude Code's binary is named after its version ("2.1.311"), argv[0] is "claude".
// ponytail: first word only, so an argv[0] path with a space in it gets cut; fine for terminal commands.
static NSString *commandName(pid_t pid) {
  char buf[4096];  // argc, the exec path, then argv[0]: the first 4 KB hold them unless the path is huge
  size_t size = sizeof buf;
  int mib[3] = {CTL_KERN, KERN_PROCARGS2, pid};
  if (sysctl(mib, 3, buf, &size, NULL, 0) != 0 || size <= sizeof(int)) return nil;
  char *p = buf + sizeof(int), *end = buf + size;
  p += strnlen(p, end - p);           // skip the exec path
  while (p < end && *p == '\0') p++;  // and the padding after it
  if (p >= end) return nil;
  NSString *arg0 = [[NSString alloc] initWithBytes:p length:strnlen(p, end - p) encoding:NSUTF8StringEncoding];
  NSString *first = [arg0 componentsSeparatedByString:@" "].firstObject;
  if ([first hasPrefix:@"-"]) first = [first substringFromIndex:1];
  return first.lastPathComponent.length ? first.lastPathComponent : nil;
}

// Calls block for every process we may inspect (our own user's), with its name and whether it has a terminal.
static void eachProcess(void (^block)(NSString *name, BOOL inTerminal, BOOL *stop)) {
  int count = proc_listallpids(NULL, 0);
  if (count <= 0) return;
  NSMutableData *pids = [NSMutableData dataWithLength:(count + 64) * sizeof(pid_t)];  // room for new processes
  count = proc_listallpids(pids.mutableBytes, (int)pids.length);
  BOOL stop = NO;
  for (int i = 0; i < count && !stop; i++) {
    pid_t pid = ((pid_t *)pids.mutableBytes)[i];
    NSString *name = commandName(pid);
    if (!name) continue;
    struct proc_bsdinfo info;
    BOOL tty = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof info) == sizeof info && (dev_t)info.e_tdev != NODEV;
    block(name, tty, &stop);
  }
}

@implementation LOProcesses

+ (NSArray<NSRunningApplication *> *)regularApps {
  NSMutableSet<NSString *> *seen = [NSMutableSet set];  // a second copy of the same app is listed once
  NSPredicate *regular = [NSPredicate predicateWithBlock:^BOOL(NSRunningApplication *a, id _) {
    if (a.activationPolicy != NSApplicationActivationPolicyRegular || !a.bundleIdentifier || !a.localizedName) return NO;
    if ([seen containsObject:a.bundleIdentifier]) return NO;
    [seen addObject:a.bundleIdentifier];
    return YES;
  }];
  NSArray *apps = [NSWorkspace.sharedWorkspace.runningApplications filteredArrayUsingPredicate:regular];
  return [apps sortedArrayUsingDescriptors:@[[NSSortDescriptor sortDescriptorWithKey:@"localizedName" ascending:YES
                                                                            selector:@selector(localizedCaseInsensitiveCompare:)]]];
}

+ (NSArray<NSString *> *)terminalCommands {
  NSSet *shells = [NSSet setWithArray:@[@"zsh", @"bash", @"sh", @"fish", @"tcsh", @"csh", @"ksh", @"dash", @"login", @"ps"]];
  NSMutableSet<NSString *> *names = [NSMutableSet set];
  eachProcess(^(NSString *name, BOOL inTerminal, BOOL *stop) {
    if (inTerminal && ![shells containsObject:name]) [names addObject:name];
  });
  return [names.allObjects sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
}

+ (BOOL)anyRunningApps:(NSArray<NSString *> *)bundleIDs commands:(NSArray<NSString *> *)names {
  for (NSString *bundleID in bundleIDs)
    if ([NSRunningApplication runningApplicationsWithBundleIdentifier:bundleID].count) return YES;
  if (!names.count) return NO;
  NSSet *wanted = [NSSet setWithArray:names];
  __block BOOL found = NO;
  eachProcess(^(NSString *name, BOOL inTerminal, BOOL *stop) {
    if ([wanted containsObject:name]) found = *stop = YES;
  });
  return found;
}

@end
