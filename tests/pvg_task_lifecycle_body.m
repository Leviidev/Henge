@interface CachedObject : NSObject
@property(nonatomic) NSData *entry;
@property(nonatomic) NSString *function;
@end
@implementation CachedObject
@end
static CachedObject *makeObject(NSString *function) {
    CachedObject *o = [CachedObject new];
    const uint32_t entry[] = {0x100006, 0x10000, 0};
    o.entry = [NSData dataWithBytes:entry length:sizeof entry]; o.function = function;
    return o;
}
static void check(BOOL ok, NSString *name) {
    if (!ok) { fprintf(stderr, "FAIL %s\n", name.UTF8String); exit(1); }
    printf("PASS %s\n", name.UTF8String);
}
int main(void) { @autoreleasepool {
    NSMutableDictionary *tasks = [NSMutableDictionary new];
    uint64_t seen[512] = {0};
    HvPvgLite *p = calloc(1, sizeof *p);
    uint32_t destroy26[] = {26}, create26[] = {52,0,4,0x382fd};
    tasks[@26] = [@{@1:makeObject(@"normal")} mutableCopy];
    tasks[@13] = [@{@1:makeObject(@"unrelated")} mutableCopy];
    check(task_cache_lifecycle(tasks,0x20,destroy26,4) && !tasks[@26] && tasks[@13], @"destroy direct 26, preserve unrelated 13");
    uint32_t destroy23[] = {23};
    tasks[@23] = [@{@1:makeObject(@"normal")} mutableCopy]; tasks[@11] = @{@1:@"other"};
    check(task_cache_lifecycle(tasks,0x20,destroy23,4) && !tasks[@23] && tasks[@11], @"fresh captured destroy direct 23, preserve 11");
    tasks[@26] = [@{@1:makeObject(@"normal")} mutableCopy];
    check(task_cache_lifecycle(tasks,0x38,create26,16) && !tasks[@26] && tasks[@13], @"ordered create clears prior task cache");
    task_created(p,26,0x382fd);
    task_cache_generation(tasks,seen,26,hv_pvg_lite_task_generation(p,26));
    CachedObject *normal = makeObject(@"normal");
    tasks[@26] = [@{@1:normal} mutableCopy];
    task_cache_generation(tasks,seen,26,hv_pvg_lite_task_generation(p,26));
    check(tasks[@26][@1] == normal, @"same generation retains valid cache");
    p->task_objects[26] = 0x4000; p->task_placement[26] = 0x8000; 
#if HV_TEST_HAS_LEGACY_TABLE
    p->legacy_object_table[26] = 1;
#endif
    p->task_objects[13] = 0x123400;
    uint64_t prior = hv_pvg_lite_task_generation(p,26);
    task_created(p,26,0x382fd); /* root-ring path, no worker create */
    BOOL legacyReset = YES;
#if HV_TEST_HAS_LEGACY_TABLE
    legacyReset = !p->legacy_object_table[26];
#endif
    check(hv_pvg_lite_task_generation(p,26)==prior+1 && p->task_root[26]==0x382fd && !p->task_objects[26] && !p->task_placement[26] && legacyReset && p->task_objects[13]==0x123400, @"same-root create resets list and detection metadata, preserves other task");
    task_cache_generation(tasks,seen,26,hv_pvg_lite_task_generation(p,26));
    check(!tasks[@26] && tasks[@13], @"root-ring creation epoch invalidates old objects");
    CachedObject *compensated = makeObject(@"compensated");
    tasks[@26] = [@{@1:compensated} mutableCopy];
    check([normal.entry isEqual:compensated.entry] && tasks[@26][@1] != normal && [tasks[@26][@1] function] == compensated.function, @"identical 12-byte entry can select new function after lifetime reset");
    NSArray *inflightOwnership = @[compensated]; __weak CachedObject *retained = compensated;
    compensated = nil;
    task_cache_lifecycle(tasks,0x20,destroy26,4);
    check(retained != nil && inflightOwnership[0] == retained, @"cache eviction preserves independently retained work resources");
    uint64_t beforeDestroy = hv_pvg_lite_task_generation(p,26);
    check(beforeDestroy==prior+1 && p->task_root[26]==0x382fd, @"worker destroy cannot clear newer device metadata");
    task_created(p,26,0x3a947);
    check(hv_pvg_lite_task_generation(p,26)==beforeDestroy+1 && p->task_root[26]==0x3a947, @"different-root create also increments identity");
    /* Regression control: old expression demonstrably deletes the wrong entry. */
    tasks[@26] = @{@1:@"old"}; tasks[@13] = @{@1:@"unrelated"};
    [tasks removeObjectForKey:@(destroy26[0]>>1)];
    check(tasks[@26] && !tasks[@13], @"old implementation negative control reproduces wrong eviction");
    free(p);
    puts("11 checks passed; no GPU API calls");
} return 0; }
