/* Process-local discovery experiment. No registry, system file or capability writes. */
#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#include <stdio.h>
#include <string.h>

static BOOL enabled(void) { const char *v=getenv("HENGE_CGL_DISCOVERY_TEST"); return v && !strcmp(v,"1"); }
static BOOL paravirtual(io_registry_entry_t entry) {
    io_name_t name={0}; IOObjectGetClass(entry,name);
    return strstr(name,"AppleParavirt") != NULL;
}
static BOOL glKey(CFStringRef key) { return key && (CFEqual(key,CFSTR("IOGLBundleName")) || CFEqual(key,CFSTR("IOGLMetalBundleName"))); }
static void trace(io_registry_entry_t entry,CFStringRef key,CFTypeRef old,BOOL changed,const char *api) {
    io_name_t name={0}; uint64_t ident=0; char k[128]={0};
    IOObjectGetClass(entry,name); IORegistryEntryGetRegistryEntryID(entry,&ident);
    if(key)CFStringGetCString(key,k,sizeof(k),kCFStringEncodingUTF8);
    fprintf(stderr,"CGLDISCOVERY api=%s class=%s registry=%llu key=%s present=%d override=%d\n",api,name,(unsigned long long)ident,k,old!=NULL,changed);
}
static CFTypeRef replacement(io_registry_entry_t entry,CFStringRef key,CFTypeRef original,const char *api) {
    if(!glKey(key))return original;
    BOOL change=enabled() && !original && CFEqual(key,CFSTR("IOGLBundleName")) && paravirtual(entry);
    trace(entry,key,original,change,api);
    return change ? CFRetain(CFSTR("AppleMetalOpenGLRenderer")) : original;
}
static CFTypeRef createProperty(io_registry_entry_t e,CFStringRef k,CFAllocatorRef a,IOOptionBits o) {
    return replacement(e,k,IORegistryEntryCreateCFProperty(e,k,a,o),"create");
}
static CFTypeRef searchProperty(io_registry_entry_t e,const io_name_t p,CFStringRef k,CFAllocatorRef a,IOOptionBits o) {
    return replacement(e,k,IORegistryEntrySearchCFProperty(e,p,k,a,o),"search");
}
static kern_return_t createProperties(io_registry_entry_t e,CFMutableDictionaryRef *p,CFAllocatorRef a,IOOptionBits o) {
    kern_return_t r=IORegistryEntryCreateCFProperties(e,p,a,o);
    if(r==KERN_SUCCESS && p && *p && paravirtual(e)) {
        CFTypeRef old=CFDictionaryGetValue(*p,CFSTR("IOGLBundleName"));
        BOOL change=enabled()&&!old; trace(e,CFSTR("IOGLBundleName"),old,change,"properties");
        if(change) { CFMutableDictionaryRef copy=CFDictionaryCreateMutableCopy(a,0,*p); CFDictionarySetValue(copy,CFSTR("IOGLBundleName"),CFSTR("AppleMetalOpenGLRenderer")); CFRelease(*p); *p=copy; }
    }
    return r;
}
#define INTERPOSE(new,old) __attribute__((used)) static const struct {const void *replacement; const void *replacee;} ip_##old __attribute__((section("__DATA,__interpose")))={(const void *)&new,(const void *)&old};
INTERPOSE(createProperty,IORegistryEntryCreateCFProperty)
INTERPOSE(searchProperty,IORegistryEntrySearchCFProperty)
INTERPOSE(createProperties,IORegistryEntryCreateCFProperties)
