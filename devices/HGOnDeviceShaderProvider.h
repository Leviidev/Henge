#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
typedef NS_ENUM(NSInteger, HGOnDeviceShaderStatus) {
    HGOnDeviceShaderPending = 0,
    HGOnDeviceShaderReady = 1,
    HGOnDeviceShaderFailed = 2,
};
@interface HGOnDeviceShaderResult : NSObject
@property(nonatomic,readonly) HGOnDeviceShaderStatus status;
@property(nonatomic,copy,readonly) NSString *sourceSHA;
@property(nonatomic,copy,readonly) NSString *recipe;
@property(nonatomic,copy,readonly) NSString *route;
@property(nonatomic,copy,readonly) NSDictionary<NSString*,NSNumber*> *timings;
@property(nonatomic,copy,readonly,nullable) NSData *output;
@property(nonatomic,copy,readonly,nullable) NSDictionary *receipt;
@property(nonatomic,strong,readonly,nullable) NSError *error;
@end
@interface HGOnDeviceShaderProvider : NSObject
- (nullable instancetype)initWithDocuments:(NSString *)documents error:(NSError **)error;
- (nullable instancetype)initWithDocuments:(NSString *)documents cacheNamespace:(NSString *)cacheNamespace error:(NSError **)error;
@property(nonatomic,copy,readonly) NSString *cacheNamespace;
@property(nonatomic,copy,readonly) NSString *recipe;
// Memory-only; missing/evicted source returns Pending, route="not-requested".
- (HGOnDeviceShaderResult *)snapshotForSourceSHA:(NSString *)sourceSHA;
// Deep-copies immutable source snapshot before async use. Never parses, waits,
// performs disk I/O, invokes Metal or calls completion inline on caller thread.
// Pending route="backpressure" is retryable capacity pressure, NOT shader failure.
// One replay completion queue per provider; wake registrations coalesce per queue.
// Wake is always async on supplied queue; caller uses weak replay + stop/epoch guard.
- (HGOnDeviceShaderResult *)requestSource:(NSData *)source
                             sourceSHA:(NSString *)sourceSHA
                       completionQueue:(dispatch_queue_t)queue
                            completion:(dispatch_block_t)wake;
// Suppresses subsequent wakes/in-memory results. Running CPU work exits normally;
// an already-started atomic cache write may finish with valid content.
- (void)invalidate;
@end
NS_ASSUME_NONNULL_END
