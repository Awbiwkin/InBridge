#import <UIKit/UIKit.h>
#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <notify.h>

#define DOM    @"com.lain.bridge"
#define STATUS @"/var/mobile/Library/Preferences/com.lain.bridge.status.plist"
#define LOGF   @"/var/mobile/Library/Preferences/com.lain.bridge.log.txt"

@interface LBRootListController : PSListController
@end

static PSSpecifier *Group(NSString *title, NSString *footer) {
    PSSpecifier *g = [PSSpecifier groupSpecifierWithName:title];
    if (footer) [g setProperty:footer forKey:@"footerText"];
    return g;
}

static PSSpecifier *Edit(id t, NSString *label, NSString *key, NSString *def) {
    PSSpecifier *p = [PSSpecifier preferenceSpecifierNamed:label target:t
                                                       set:@selector(setPreferenceValue:specifier:)
                                                       get:@selector(readPreferenceValue:)
                                                    detail:nil cell:PSEditTextCell edit:nil];
    [p setProperty:DOM forKey:@"defaults"];
    [p setProperty:key forKey:@"key"];
    if (def) [p setProperty:def forKey:@"default"];
    [p setProperty:@YES forKey:@"noAutoCorrect"];
    return p;
}

static PSSpecifier *Btn(id t, NSString *label, SEL sel) {
    PSSpecifier *b = [PSSpecifier preferenceSpecifierNamed:label target:t set:nil get:nil detail:nil cell:PSButtonCell edit:nil];
    b.buttonAction = sel;
    return b;
}

static NSString *LogTail(NSUInteger n) {
    NSString *all = [NSString stringWithContentsOfFile:LOGF encoding:NSUTF8StringEncoding error:nil];
    if (!all.length) return @"(log empty: is lainbridged running? try respring / reinstall)";
    NSArray *l = [all componentsSeparatedByString:@"\n"];
    NSUInteger from = l.count > n + 1 ? l.count - n - 1 : 0;
    return [[l subarrayWithRange:NSMakeRange(from, l.count - from)] componentsJoinedByString:@"\n"];
}

@implementation LBRootListController

- (NSArray *)specifiers {
    if (_specifiers) return _specifiers;
    NSDictionary *st = [NSDictionary dictionaryWithContentsOfFile:STATUS] ?: @{};
    NSArray *modeNames = @[@"off", @"menu 1 // wifi chain", @"menu 2 // sim relay"];
    NSInteger mi = [st[@"mode"] integerValue];
    NSString *summary = [NSString stringWithFormat:
        @"mode: %@\nhotspot: %@   en0: %@   hs: %@\npdp_ip0: %@\npf: %@\nconflict: %@\ncheck: %@",
        modeNames[(NSUInteger)MAX(0, MIN(2, mi))],
        [st[@"hotspotUp"] boolValue] ? @"UP" : @"down",
        st[@"en0ip"] ?: @"-", st[@"hsip"] ?: @"-", st[@"pdp0"] ?: @"-",
        st[@"pf"] ?: @"-", st[@"conflict"] ?: @"-", st[@"check"] ?: @"-"];

    NSMutableArray *s = [NSMutableArray array];
    [s addObject:Group(@"LAIN // BRIDGE  ::  layer 07", summary)];

    PSSpecifier *mode = [PSSpecifier preferenceSpecifierNamed:@"mode" target:self
                                                          set:@selector(setPreferenceValue:specifier:)
                                                          get:@selector(readPreferenceValue:)
                                                       detail:NSClassFromString(@"PSListItemsController")
                                                         cell:PSLinkListCell edit:nil];
    [mode setProperty:DOM forKey:@"defaults"];
    [mode setProperty:@"mode" forKey:@"key"];
    [mode setProperty:@0 forKey:@"default"];
    [mode setValues:@[@0, @1, @2] titles:modeNames];
    [s addObject:mode];

    [s addObject:Group(@"menu 1 // wired chain",
        @"iPhone 14 PM hotspot -> this phone (wifi) -> hotspot -> clients. exit TTL is scrubbed on en0. "
        @"join the 14 PM hotspot by hand once so it is a known network, then type its name here.")];
    [s addObject:Edit(self, @"uplink ssid", @"uplinkSSID", @"")];

    [s addObject:Group(@"menu 2 // sim relay",
        @"SIM in this phone -> hotspot -> clients. exit TTL is scrubbed on pdp_ip0. nothing else to set.")];

    [s addObject:Group(@"common", @"exit ttl is what the carrier should see (64 normally). hotspot name takes effect after restart.")];
    [s addObject:Edit(self, @"hotspot name", @"ssid", nil)];
    [s addObject:Edit(self, @"exit ttl", @"ttl", @"64")];

    [s addObject:Group(@"control", @"apply -> then switch the hotspot on in Settings. check = internet probe + pf state.")];
    [s addObject:Btn(self, @"[ apply ]", @selector(doApply))];
    [s addObject:Btn(self, @"[ check connection ]", @selector(doCheck))];
    [s addObject:Btn(self, @"[ restart sharing ]", @selector(doRestart))];
    [s addObject:Btn(self, @"[ refresh ]", @selector(doRefresh))];
    [s addObject:Btn(self, @"[ copy full log ]", @selector(doCopy))];

    [s addObject:Group(@"log", LogTail(14))];

    _specifiers = [s copy];
    return _specifiers;
}

- (void)refreshSoon {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ [self reloadSpecifiers]; });
}

- (void)doApply {
    CFPreferencesAppSynchronize((__bridge CFStringRef)DOM);
    notify_post("com.lain.bridge/apply");
    [self refreshSoon];
}
- (void)doCheck { notify_post("com.lain.bridge/check"); dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ [self reloadSpecifiers]; }); }
- (void)doRestart { notify_post("com.lain.bridge/restart"); dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 8 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ [self reloadSpecifiers]; }); }
- (void)doRefresh { [self reloadSpecifiers]; }
- (void)doCopy {
    NSString *all = [NSString stringWithContentsOfFile:LOGF encoding:NSUTF8StringEncoding error:nil] ?: @"(no log)";
    [UIPasteboard generalPasteboard].string = all;
}

@end
