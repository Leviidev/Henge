#import "display_settings.h"
#include "cursor_density.h"
#import <objc/runtime.h>
#include <assert.h>
#include <pthread.h>
#include <stdio.h>
#include <time.h>
#include <unistd.h>

static _Atomic unsigned reads;
static id (*real_object)(id,SEL,id);
static NSInteger (*real_integer)(id,SEL,id);
static id object_count(id obj,SEL sel,id key) {
    atomic_fetch_add(&reads,1); return real_object(obj,sel,key);
}
static NSInteger integer_count(id obj,SEL sel,id key) {
    atomic_fetch_add(&reads,1); return real_integer(obj,sel,key);
}
static void notify(void) {
    [NSNotificationCenter.defaultCenter postNotificationName:NSUserDefaultsDidChangeNotification object:NSUserDefaults.standardUserDefaults];
}
static void *reader(void *unused) {
    (void)unused;
    @autoreleasepool {
        for(unsigned i=0;i<200000;i++) {
            HvDisplaySettings s=hv_display_settings_get();
            assert(s.scale<=3);
        }
    }
    return NULL;
}
int main(void) { @autoreleasepool {
    alarm(20);
    NSUserDefaults *p=NSUserDefaults.standardUserDefaults;
    [p removeObjectForKey:@"henge.cursor.scale"];[p removeObjectForKey:@"henge.cursor.sharp"];
    Method om=class_getInstanceMethod(NSUserDefaults.class,@selector(objectForKey:));
    Method im=class_getInstanceMethod(NSUserDefaults.class,@selector(integerForKey:));
    real_object=(void *)method_setImplementation(om,(IMP)object_count);
    real_integer=(void *)method_setImplementation(im,(IMP)integer_count);
    HvDisplaySettings initial=hv_display_settings_get();assert(initial.sharp);
    assert(hv_cursor_density_scale(0,2752,281,3)==1);
    assert(hv_cursor_density_scale(0,1920,400,3)==3);
    assert(hv_cursor_density_scale(0,0,0,1)==1);
    assert(hv_cursor_density_scale(3,2752,281,1)==3);
    [p setInteger:2 forKey:@"henge.cursor.scale"];notify();assert(hv_display_settings_get().scale==2);
    [p setInteger:0 forKey:@"henge.cursor.scale"];notify();assert(hv_display_settings_get().scale==0);
    initial=hv_display_settings_get();
    unsigned uncached=atomic_load(&reads);
    for(unsigned i=0;i<10;i++)(void)[p objectForKey:@"henge.cursor.sharp"];
    assert(atomic_load(&reads)>=uncached+10); /* prove the lookup counter is live */
    unsigned before=atomic_load(&reads);
    for(unsigned i=0;i<200000;i++) {
        HvDisplaySettings s=hv_display_settings_get();assert(s.scale==initial.scale && s.sharp);
    }
    assert(atomic_load(&reads)==before); /* zero defaults reads on the render path */
    [p setBool:NO forKey:@"henge.cursor.sharp"];notify();assert(!hv_display_settings_get().sharp);
    [p removeObjectForKey:@"henge.cursor.sharp"];notify();assert(hv_display_settings_get().sharp);
    [p setInteger:60 forKey:@"henge.perf.presentationCap"];
    [p setBool:YES forKey:@"henge.perf.thermalProtection"];notify();
    assert(hv_display_settings_get().presentation_cap == 60 && hv_display_settings_get().thermal_protection);
    [p setBool:NO forKey:@"henge.perf.lowPowerAware"];notify();assert(!hv_display_settings_get().power_aware);
    [p setBool:YES forKey:@"henge.perf.lowPowerAware"];notify();assert(hv_display_settings_get().power_aware);
    [p setInteger:30 forKey:@"henge.perf.presentationCap"];notify();
    assert(hv_display_settings_get().presentation_cap == 30);
    [p removeObjectForKey:@"henge.perf.presentationCap"];
    [p removeObjectForKey:@"henge.perf.thermalProtection"];notify();
    assert(hv_display_settings_get().presentation_cap == 0 && !hv_display_settings_get().thermal_protection);
    pthread_t threads[4];
    for(unsigned i=0;i<4;i++)assert(!pthread_create(&threads[i],NULL,reader,NULL));
    for(unsigned i=0;i<1000;i++){[p setBool:(i&1) forKey:@"henge.cursor.sharp"];notify();}
    for(unsigned i=0;i<4;i++)assert(!pthread_join(threads[i],NULL));
    [p removeObjectForKey:@"henge.cursor.sharp"];notify();assert(hv_display_settings_get().sharp);
    method_setImplementation(om,(IMP)real_object);method_setImplementation(im,(IMP)real_integer);
    puts("PASS display settings: 200000 frame reads -> zero preferences lookups; live notifications, defaults and concurrent readers preserved; no polling timer");
} }
