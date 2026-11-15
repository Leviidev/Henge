#pragma once
#import <Foundation/Foundation.h>
#include <stdatomic.h>
#include <stdbool.h>

/* One optional compiler worker, with at most two retained requests. Required
   classic pipelines continue to serve frames while these variants warm up.
   Keep this queue separate from archive disk I/O. */
@interface HvMetal4CompileQueue : NSObject {
    dispatch_queue_t _queue;
    _Atomic unsigned _pending;
    _Atomic bool _enabled;
    _Atomic bool _suspended;
@public
    _Atomic uint64_t admitted,completed,deferred,cancelled;
}
- (BOOL)enqueue:(void (^)(BOOL allowed))operation;
- (void)setEnabled:(BOOL)enabled;
- (void)setSuspended:(BOOL)suspended;
@end
@implementation HvMetal4CompileQueue
- (instancetype)init {
    if(!(self=[super init]))return nil;
    _queue=dispatch_queue_create("hengevm.metal4.compile",dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,QOS_CLASS_UTILITY,0));
    atomic_store(&_enabled,true);return self;
}
- (void)setEnabled:(BOOL)enabled {atomic_store(&_enabled,enabled);}
- (void)setSuspended:(BOOL)suspended {atomic_store(&_suspended,suspended);}
- (BOOL)enqueue:(void (^)(BOOL allowed))operation {
    if(!operation)return NO;
    unsigned pending=atomic_load(&_pending);
    for(;;) {
        if(!atomic_load(&_enabled)||atomic_load(&_suspended)||pending>=2){atomic_fetch_add(&deferred,1);return NO;}
        if(atomic_compare_exchange_weak(&_pending,&pending,pending+1))break;
    }
    atomic_fetch_add(&admitted,1);
    dispatch_async(_queue,^{@autoreleasepool{
        BOOL allowed=atomic_load(&self->_enabled)&&!atomic_load(&self->_suspended);
        if(!allowed)atomic_fetch_add(&self->cancelled,1);
        @try{operation(allowed);}
        @finally{atomic_fetch_sub(&self->_pending,1);atomic_fetch_add(&self->completed,1);}
    }});
    return YES;
}
@end
