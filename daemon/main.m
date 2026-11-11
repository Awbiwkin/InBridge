// lainbridged -- root daemon. wired // layer 07
// Menu 1: iPhone14PM wifi -> 6s (en0) -> hotspot clients, exit TTL scrub on en0
// Menu 2: SIM in 6s (pdp_ip0) -> hotspot clients, exit TTL scrub on pdp_ip0
// Everything it does is written to the log so a failed method tells us exactly where it broke.

#import <Foundation/Foundation.h>
#import <notify.h>
#import <spawn.h>
#import <ifaddrs.h>
#import <net/if.h>
#import <arpa/inet.h>
#import <sys/sysctl.h>
#import <sys/stat.h>
#import <sys/wait.h>
#import <dlfcn.h>
#import <unistd.h>

extern char **environ;

#define PREFS_PATH  @"/var/mobile/Library/Preferences/com.lain.bridge.plist"
#define STATUS_PATH @"/var/mobile/Library/Preferences/com.lain.bridge.status.plist"
#define LOG_PATH    @"/var/mobile/Library/Preferences/com.lain.bridge.log.txt"
#define PF_FILE     @"/tmp/lainbridge.pf"

static NSMutableDictionary *gStatus;
static BOOL gHotspotWas = NO;
static NSTimeInterval gLastRejoin = 0;
static NSString *gAnchor = nil;
static int gTok[3];
static dispatch_source_t gTimer;

#pragma mark - util

static void Give(NSString *p) {
    chown(p.fileSystemRepresentation, 501, 501);
    chmod(p.fileSystemRepresentation, 0644);
}

static void LOG(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void LOG(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    struct stat st;
    if (stat(LOG_PATH.fileSystemRepresentation, &st) == 0 && st.st_size > 60000) unlink(LOG_PATH.fileSystemRepresentation);
    time_t t = time(NULL); struct tm tmv; localtime_r(&t, &tmv);
    char ts[16]; strftime(ts, sizeof ts, "%H:%M:%S", &tmv);
    FILE *f = fopen(LOG_PATH.fileSystemRepresentation, "a");
    if (f) { fprintf(f, "%s %s\n", ts, s.UTF8String); fclose(f); Give(LOG_PATH); }
}

static void Put(NSString *k, id v) { @synchronized (gStatus) { gStatus[k] = v ?: @""; } }
static void Flush(void) {
    @synchronized (gStatus) {
        [gStatus writeToFile:STATUS_PATH atomically:YES];
    }
    Give(STATUS_PATH);
}

static NSString *Run(NSArray<NSString *> *args) {
    int pfd[2];
    if (pipe(pfd) != 0) return @"(pipe failed)";
    posix_spawn_file_actions_t fa;
    posix_spawn_file_actions_init(&fa);
    posix_spawn_file_actions_adddup2(&fa, pfd[1], 1);
    posix_spawn_file_actions_adddup2(&fa, pfd[1], 2);
    posix_spawn_file_actions_addclose(&fa, pfd[0]);
    posix_spawn_file_actions_addclose(&fa, pfd[1]);
    char **argv = calloc(args.count + 1, sizeof(char *));
    for (NSUInteger i = 0; i < args.count; i++) argv[i] = (char *)args[i].UTF8String;
    pid_t pid = 0;
    int rc = posix_spawn(&pid, argv[0], &fa, NULL, argv, environ);
    close(pfd[1]);
    NSMutableData *d = [NSMutableData data];
    if (rc == 0) {
        char buf[2048]; ssize_t n;
        while ((n = read(pfd[0], buf, sizeof buf)) > 0) [d appendBytes:buf length:(NSUInteger)n];
        int stt = 0; waitpid(pid, &stt, 0);
    } else {
        d = [[[NSString stringWithFormat:@"spawn failed rc=%d", rc] dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
    }
    close(pfd[0]);
    posix_spawn_file_actions_destroy(&fa);
    free(argv);
    NSString *o = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] ?: @"";
    return [o stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

static NSString *Bin(NSString *name) {
    for (NSString *dir in @[@"/var/jb/usr/sbin", @"/var/jb/sbin", @"/var/jb/usr/bin", @"/var/jb/bin",
                            @"/sbin", @"/usr/sbin", @"/usr/bin", @"/bin"]) {
        NSString *p = [dir stringByAppendingPathComponent:name];
        if ([[NSFileManager defaultManager] isExecutableFileAtPath:p]) return p;
    }
    return nil;
}

static NSDictionary *Cfg(void) { return [NSDictionary dictionaryWithContentsOfFile:PREFS_PATH] ?: @{}; }
static NSInteger CfgInt(NSString *k, NSInteger d) { id v = Cfg()[k]; return v ? [v integerValue] : d; }

static NSDictionary *Ifaces(void) {
    NSMutableDictionary *m = [NSMutableDictionary dictionary];
    struct ifaddrs *ifa = NULL, *c;
    if (getifaddrs(&ifa) != 0) return m;
    for (c = ifa; c; c = c->ifa_next) {
        NSString *n = @(c->ifa_name);
        NSMutableDictionary *e = m[n];
        if (!e) { e = [NSMutableDictionary dictionary]; m[n] = e; }
        BOOL up = (c->ifa_flags & IFF_UP) && (c->ifa_flags & IFF_RUNNING);
        e[@"up"] = @(up);
        if (c->ifa_addr && c->ifa_addr->sa_family == AF_INET) {
            char b[INET_ADDRSTRLEN];
            inet_ntop(AF_INET, &((struct sockaddr_in *)c->ifa_addr)->sin_addr, b, sizeof b);
            e[@"ip"] = @(b);
        }
    }
    freeifaddrs(ifa);
    return m;
}

static NSString *Net28(NSString *ip) {
    unsigned a, b, c, d;
    if (!ip || sscanf(ip.UTF8String, "%u.%u.%u.%u", &a, &b, &c, &d) != 4) return nil;
    return [NSString stringWithFormat:@"%u.%u.%u.%u/28", a, b, c, d & 0xF0];
}

static void SetSysctl(const char *name, int v) {
    int old = 0; size_t l = sizeof old;
    int r = sysctlbyname(name, &old, &l, &v, sizeof v);
    LOG(@"sysctl %s: %d -> %d (rc=%d errno=%d)", name, old, v, r, r ? errno : 0);
}

static int GetSysctl(const char *name) {
    int v = -1; size_t l = sizeof v;
    sysctlbyname(name, &v, &l, NULL, 0);
    return v;
}

#pragma mark - method: hotspot name

static void SetName(NSString *name) {
    void *h = dlopen("/usr/lib/libMobileGestalt.dylib", RTLD_LAZY);
    int (*MGSet)(CFStringRef, CFTypeRef) = h ? dlsym(h, "MGSetAnswer") : NULL;
    if (!MGSet) { LOG(@"name: MGSetAnswer not found"); return; }
    int r = MGSet(CFSTR("UserAssignedDeviceName"), (__bridge CFTypeRef)name);
    LOG(@"name: MGSetAnswer(\"%@\") rc=%d (restart hotspot to see it)", name, r);
}

#pragma mark - method: rejoin uplink wifi while hotspot is up (private MobileWiFi API, all via dlsym)

static void AssocCB(void *a, void *b, int c, void *d) { LOG(@"rejoin: assoc callback fired rc=%d", c); }

static void TryRejoin(NSString *ssid) {
    if (!ssid.length) { LOG(@"rejoin: set 'uplink ssid' (14PM hotspot name) in Settings first"); return; }
    void *h = dlopen("/System/Library/PrivateFrameworks/MobileWiFi.framework/MobileWiFi", RTLD_LAZY);
    if (!h) { LOG(@"rejoin: dlopen MobileWiFi failed"); return; }
    void *(*Create)(CFAllocatorRef, long) = dlsym(h, "WiFiManagerClientCreate");
    CFArrayRef (*Devs)(void *) = dlsym(h, "WiFiManagerClientCopyDevices");
    CFArrayRef (*Nets)(void *) = dlsym(h, "WiFiManagerClientCopyNetworks");
    CFStringRef (*SSIDOf)(void *) = dlsym(h, "WiFiNetworkGetSSID");
    void (*Assoc)(void *, void *, void *, void *) = dlsym(h, "WiFiDeviceClientAssociateAsync");
    void (*Sched)(void *, CFRunLoopRef, CFStringRef) = dlsym(h, "WiFiManagerClientScheduleWithRunLoop");
    LOG(@"rejoin symbols: create=%d devs=%d nets=%d ssid=%d assoc=%d sched=%d",
        Create != NULL, Devs != NULL, Nets != NULL, SSIDOf != NULL, Assoc != NULL, Sched != NULL);
    if (!Create || !Devs || !Nets || !SSIDOf || !Assoc) return;
    static void *mgr = NULL;
    if (!mgr) {
        mgr = Create(kCFAllocatorDefault, 0);
        if (mgr && Sched) Sched(mgr, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
    }
    if (!mgr) { LOG(@"rejoin: manager create failed"); return; }
    NSArray *devs = CFBridgingRelease(Devs(mgr));
    NSArray *nets = CFBridgingRelease(Nets(mgr));
    LOG(@"rejoin: %lu devices, %lu known networks", (unsigned long)devs.count, (unsigned long)nets.count);
    if (!devs.count) return;
    for (id n in nets) {
        NSString *s = (__bridge NSString *)SSIDOf((__bridge void *)n);
        if ([s isEqualToString:ssid]) {
            LOG(@"rejoin: calling AssociateAsync for \"%@\" (if the log ends here, this call crashed)", ssid);
            Assoc((__bridge void *)devs[0], (__bridge void *)n, (void *)AssocCB, NULL);
            return;
        }
    }
    LOG(@"rejoin: \"%@\" not in known networks (join it once by hand first)", ssid);
}

#pragma mark - method: pf scrub min-ttl (+ optional NAT out of en0)

static BOOL ApplyPF(NSString *uplink, int minTTL, BOOL nat, NSString *hsNet) {
    NSString *pfctl = Bin(@"pfctl");
    if (!pfctl) { LOG(@"pf: pfctl NOT FOUND in any path"); Put(@"pf", @"pfctl missing"); return NO; }
    LOG(@"pf: using %@", pfctl);
    LOG(@"pf anchors: %@", Run(@[pfctl, @"-sA"]));
    NSString *mainR = Run(@[pfctl, @"-sr"]);
    LOG(@"pf main rules: %@", mainR.length ? mainR : @"(empty)");
    LOG(@"pf main nat: %@", Run(@[pfctl, @"-sn"]));
    if (![mainR containsString:@"anchor"]) LOG(@"pf WARN: main ruleset shows no anchors, our anchor may never be evaluated");
    LOG(@"pf enable: %@", Run(@[pfctl, @"-e"]));

    NSArray *anchors = @[@"com.apple/lainbridge", @"lainbridge"];
    NSArray *scrubs = @[[NSString stringWithFormat:@"scrub out on %@ all min-ttl %d", uplink, minTTL],
                        [NSString stringWithFormat:@"scrub on %@ all min-ttl %d", uplink, minTTL]];
    BOOL loadedOnly = NO;
    for (NSString *a in anchors) {
        for (NSString *sc in scrubs) {
            NSMutableString *r = [sc mutableCopy];
            [r appendString:@"\n"];
            if (nat && hsNet) [r appendFormat:@"nat on %@ inet from %@ to any -> (%@)\n", uplink, hsNet, uplink];
            [r writeToFile:PF_FILE atomically:YES encoding:NSUTF8StringEncoding error:nil];
            NSString *out = Run(@[pfctl, @"-a", a, @"-f", PF_FILE]);
            LOG(@"pf load [%@] \"%@\" -> %@", a, sc, out.length ? out : @"(no output)");
            NSString *low = out.lowercaseString;
            if ([low containsString:@"error"] || [low containsString:@"syntax"] ||
                [low containsString:@"invalid"] || [low containsString:@"usage"] || [low containsString:@"spawn failed"]) continue;
            NSString *show = Run(@[pfctl, @"-a", a, @"-sr"]);
            LOG(@"pf verify [%@]: %@", a, show.length ? show : @"(empty)");
            gAnchor = a;
            if ([show containsString:@"min-ttl"]) {
                Put(@"pfAnchor", a);
                Put(@"pf", [NSString stringWithFormat:@"scrub min-ttl %d on %@ OK", minTTL, uplink]);
                return YES;
            }
            loadedOnly = YES;
        }
    }
    Put(@"pf", loadedOnly ? @"loaded but not verified (see log)" : @"FAILED all variants (see log)");
    return NO;
}

static void ClearPF(void) {
    NSString *pfctl = Bin(@"pfctl");
    if (!pfctl) return;
    for (NSString *a in @[@"com.apple/lainbridge", @"lainbridge"]) Run(@[pfctl, @"-a", a, @"-F", @"all"]);
    LOG(@"pf: anchors flushed");
}

#pragma mark - actions

static void Apply(void) {
    NSInteger mode = CfgInt(@"mode", 0);
    NSInteger ttl = CfgInt(@"ttl", 64);
    if (ttl < 2 || ttl > 254) ttl = 64;
    NSString *name = Cfg()[@"ssid"];
    LOG(@"=== apply: mode=%ld exitTTL=%ld ===", (long)mode, (long)ttl);
    Put(@"mode", @(mode));
    Put(@"exitTTL", @(ttl));
    if ([name isKindOfClass:[NSString class]] && name.length) SetName(name);

    if (mode == 0) {
        ClearPF();
        SetSysctl("net.inet.ip.ttl", 64);
        SetSysctl("net.inet6.ip6.hlim", 64);
        Put(@"pf", @"off");
        return;
    }

    NSString *uplink = (mode == 1) ? @"en0" : @"pdp_ip0";
    // mode 1: 14 Pro Max still decrements once, so leave the 6s with TTL+1
    int minTTL = (int)ttl + (mode == 1 ? 1 : 0);
    SetSysctl("net.inet.ip.ttl", minTTL);
    SetSysctl("net.inet6.ip6.hlim", minTTL);

    NSDictionary *ifs = Ifaces();
    NSString *hsIP = ifs[@"bridge100"][@"ip"] ?: ifs[@"ap1"][@"ip"];
    NSString *hsNet = Net28(hsIP) ?: @"172.20.10.0/28";
    NSString *upNet = Net28(ifs[@"en0"][@"ip"]);
    if (mode == 1 && upNet && [upNet isEqualToString:hsNet]) {
        LOG(@"WARN subnet conflict: hotspot net %@ == uplink net %@ (routing will break; see README)", hsNet, upNet);
        Put(@"conflict", @"hotspot subnet == uplink subnet");
    } else {
        Put(@"conflict", @"none");
    }
    BOOL ok = ApplyPF(uplink, minTTL, mode == 1, hsNet);
    Put(@"pfOK", @(ok));
}

static void Check(void) {
    LOG(@"=== check ===");
    NSDictionary *ifs = Ifaces();
    Put(@"ttlLocal", [NSString stringWithFormat:@"v4=%d v6=%d", GetSysctl("net.inet.ip.ttl"), GetSysctl("net.inet6.ip6.hlim")]);
    NSString *pfctl = Bin(@"pfctl");
    if (pfctl && gAnchor) {
        NSString *s = Run(@[pfctl, @"-a", gAnchor, @"-sr"]);
        LOG(@"check: anchor %@ rules: %@", gAnchor, s.length ? s : @"(empty, misd may have wiped it)");
    }
    NSURLSessionConfiguration *c = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    c.timeoutIntervalForRequest = 6;
    NSURLSession *ses = [NSURLSession sessionWithConfiguration:c];
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    NSDate *t0 = [NSDate date];
    __block NSString *res = @"?";
    [[ses dataTaskWithURL:[NSURL URLWithString:@"http://captive.apple.com/"]
        completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        double ms = -[t0 timeIntervalSinceNow] * 1000.0;
        if (e) res = [NSString stringWithFormat:@"FAIL %@", e.localizedDescription];
        else res = [NSString stringWithFormat:@"HTTP %ld in %.0f ms", (long)((NSHTTPURLResponse *)r).statusCode, ms];
        dispatch_semaphore_signal(sem);
    }] resume];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 9 * NSEC_PER_SEC));
    LOG(@"check: internet %@ | en0=%@ pdp_ip0=%@", res, ifs[@"en0"][@"ip"] ?: @"-", ifs[@"pdp_ip0"][@"ip"] ?: @"-");
    Put(@"check", res);
    Flush();
}

static void Restart(void) {
    LOG(@"=== restart sharing ===");
    NSString *k = Bin(@"killall");
    if (k) LOG(@"killall misd: %@", Run(@[k, @"misd"]));
    else LOG(@"killall not found");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 4 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ Apply(); Flush(); });
}

static void Tick(void) {
    NSInteger mode = CfgInt(@"mode", 0);
    NSDictionary *ifs = Ifaces();
    BOOL hs = [ifs[@"ap1"][@"up"] boolValue] || ifs[@"bridge100"][@"ip"] != nil;
    NSString *en0 = ifs[@"en0"][@"ip"];
    Put(@"hotspotUp", @(hs));
    Put(@"en0ip", en0 ?: @"-");
    Put(@"hsip", ifs[@"bridge100"][@"ip"] ?: ifs[@"ap1"][@"ip"] ?: @"-");
    Put(@"pdp0", ifs[@"pdp_ip0"][@"ip"] ?: @"-");
    if (hs != gHotspotWas) {
        LOG(@"hotspot %@ | en0=%@ | ap1 up=%@ bridge100=%@", hs ? @"UP" : @"DOWN", en0 ?: @"NO-IP",
            ifs[@"ap1"][@"up"], ifs[@"bridge100"][@"ip"] ?: @"-");
        gHotspotWas = hs;
        if (hs && mode) {
            // misd rewrites its pf anchors when the hotspot toggles, so re-apply a moment later
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ Apply(); Flush(); });
        }
    }
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    if (mode == 1 && hs && !en0 && now - gLastRejoin > 20) {
        gLastRejoin = now;
        LOG(@"mode1: hotspot is up but en0 lost its IP, trying to rejoin uplink wifi");
        id s = Cfg()[@"uplinkSSID"];
        TryRejoin([s isKindOfClass:[NSString class]] ? s : nil);
    }
    Flush();
}

int main(void) {
    @autoreleasepool {
        gStatus = [NSMutableDictionary dictionary];
        LOG(@"---- lainbridged start pid=%d ----", getpid());
        dispatch_queue_t mq = dispatch_get_main_queue();
        notify_register_dispatch("com.lain.bridge/apply", &gTok[0], mq, ^(int t) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC), mq, ^{ Apply(); Flush(); });
        });
        notify_register_dispatch("com.lain.bridge/check", &gTok[1], mq, ^(int t) {
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ Check(); });
        });
        notify_register_dispatch("com.lain.bridge/restart", &gTok[2], mq, ^(int t) { Restart(); });

        gTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, mq);
        dispatch_source_set_timer(gTimer, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), 3 * NSEC_PER_SEC, NSEC_PER_SEC / 2);
        dispatch_source_set_event_handler(gTimer, ^{ Tick(); });
        dispatch_resume(gTimer);

        Apply();
        Flush();
        dispatch_main();
    }
    return 0;
}
