/* A small host-visible snapshot; never dispatch_sync to the parked replay worker. */
#import <Foundation/Foundation.h>
@interface HvRenderStatus : NSObject {
    int code;
    NSString *message;
}
- (void)setCode:(int)value message:(NSString *)text;
- (int)copyMessage:(char *)buffer length:(uint32_t)length;
@end
@implementation HvRenderStatus
- (void)setCode:(int)value message:(NSString *)text {
    @synchronized (self) { code=value;message=[text copy]; }
}
- (int)copyMessage:(char *)buffer length:(uint32_t)length {
    @synchronized (self) {
        if(buffer&&length)snprintf(buffer,length,"%s",message.UTF8String?:"");
        return code;
    }
}
@end
