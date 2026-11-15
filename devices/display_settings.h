#ifndef HENGE_DISPLAY_SETTINGS_H
#define HENGE_DISPLAY_SETTINGS_H
#import <Foundation/Foundation.h>
#import <TargetConditionals.h>
#if TARGET_OS_IPHONE
#import <UIKit/UIApplication.h>
#endif
#include <stdatomic.h>
#include <os/lock.h>
#include <sys/utsname.h>
#include <string.h>

/* The presenter and Link worker read one coherent word, with no preferences
   access or polling timer in a frame. Notifications preserve live settings. */
typedef struct { unsigned scale; BOOL sharp; int presentation_cap, thermal; BOOL thermal_protection, low_power, power_aware; } HvDisplaySettings;
static _Atomic unsigned hv_display_settings_word;
static os_unfair_lock hv_display_settings_lock = OS_UNFAIR_LOCK_INIT;
static BOOL hv_display_settings_initialized;
static unsigned hv_display_default_scale __attribute__((unused)) = 1;
static void hv_display_settings_refresh(void) {
    os_unfair_lock_lock(&hv_display_settings_lock);
    NSUserDefaults *prefs = NSUserDefaults.standardUserDefaults;
    unsigned scale = 0;
    NSInteger saved = [prefs integerForKey:@"henge.cursor.scale"];
    scale = saved >= 1 && saved <= 3 ? (unsigned)saved : 0;
    id sharp = [prefs objectForKey:@"henge.cursor.sharp"];
    NSInteger selected = [prefs integerForKey:@"henge.perf.presentationCap"];
    unsigned cap = selected == 30 ? 1 : selected == 60 ? 2 : 0;
    unsigned thermal = (unsigned)NSProcessInfo.processInfo.thermalState;
    BOOL powerAware = [prefs objectForKey:@"henge.perf.lowPowerAware"] == nil || [prefs boolForKey:@"henge.perf.lowPowerAware"];
    unsigned word = scale | ((!sharp || [sharp boolValue]) ? 4u : 0u) | cap << 3 |
                    ([prefs boolForKey:@"henge.perf.thermalProtection"] ? 32u : 0u) | ((thermal & 3u) << 6) |
                    (powerAware ? 256u : 0u) | (NSProcessInfo.processInfo.lowPowerModeEnabled ? 512u : 0u);
    unsigned previous = atomic_exchange_explicit(&hv_display_settings_word, word, memory_order_acq_rel);
    BOOL notify=hv_display_settings_initialized && previous!=word;
    hv_display_settings_initialized=YES;
    os_unfair_lock_unlock(&hv_display_settings_lock);
    if (notify)
        [NSNotificationCenter.defaultCenter postNotificationName:@"HengeDisplaySettingsDidChange" object:nil];
}
static HvDisplaySettings hv_display_settings_get(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
#if TARGET_OS_IPHONE
        struct utsname u;
        hv_display_default_scale = !uname(&u) && !strncmp(u.machine,"iPad",4) ? 1 : 3;
#endif
        /* Process-lifetime cache, shared by this translation unit's replay
           instances; the observer captures no replay or display resources. */
        static id observer, thermalObserver, powerObserver;
        observer = [NSNotificationCenter.defaultCenter addObserverForName:NSUserDefaultsDidChangeNotification
            object:nil queue:nil usingBlock:^(NSNotification *note) { (void)note; hv_display_settings_refresh(); }];
        (void)observer;
        thermalObserver = [NSNotificationCenter.defaultCenter addObserverForName:NSProcessInfoThermalStateDidChangeNotification
            object:nil queue:nil usingBlock:^(NSNotification *note) { (void)note; hv_display_settings_refresh(); }];
        (void)thermalObserver;
        powerObserver = [NSNotificationCenter.defaultCenter addObserverForName:NSProcessInfoPowerStateDidChangeNotification
            object:nil queue:nil usingBlock:^(NSNotification *note) { (void)note; hv_display_settings_refresh(); }];
        (void)powerObserver;
#if TARGET_OS_IPHONE
        static id foregroundObserver;
        foregroundObserver = [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification
            object:nil queue:nil usingBlock:^(NSNotification *note) { (void)note; hv_display_settings_refresh(); }];
        (void)foregroundObserver;
#endif
        hv_display_settings_refresh();
    });
    unsigned word = atomic_load_explicit(&hv_display_settings_word,memory_order_acquire);
    unsigned cap = (word >> 3) & 3u;
    return (HvDisplaySettings){.scale=word & 3u,.sharp=(word & 4u) != 0,
        .presentation_cap=cap == 1 ? 30 : cap == 2 ? 60 : 0,
        .thermal=(int)((word >> 6) & 3u),.thermal_protection=(word & 32u) != 0,
        .power_aware=(word & 256u)!=0,.low_power=(word & 512u)!=0};
}
#endif
