/* Included in runtime.m after adapter helpers. No controller or shell process.
 */
#import <fcntl.h>
#import <sys/file.h>
#import <sys/stat.h>
#import <unistd.h>
static NSDictionary *HGConfiguration;
static NSString *HGToken;
static NSString *HGEndpoint;
static NSTimeInterval HGTimeout;
static BOOL HGEmbeddedTransport;
static NSString *HGEmbeddedRecipe;
static NSData *HGHTTP(NSString *, NSString *, NSData *, NSTimeInterval, NSInteger *, NSError **);
static BOOL HGLoadConfiguration(void) {
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    const char *path = getenv("HENGE_DYNAMIC_CONFIG");
    if (!path) {
      HGEndpoint=@"http://10.0.2.4/.henge/shaders";
#ifdef HG_ALLOW_NATIVE_TESTING
      const char *testEndpoint=getenv("HENGE_EMBEDDED_TEST_ENDPOINT");
      if(testEndpoint) HGEndpoint=@(testEndpoint);
#endif
      NSInteger status=0;
      NSData *bytes=HGHTTP(@"GET",@"/identity",nil,5,&status,nil);
      NSDictionary *identity=bytes.length && bytes.length<=16384?[NSJSONSerialization JSONObjectWithData:bytes options:0 error:nil]:nil;
      id recipe=[identity isKindOfClass:NSDictionary.class]?identity[@"recipe"]:nil;
      NSCharacterSet *bad=[[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"] invertedSet];
      if(status!=200 || ![recipe isKindOfClass:NSString.class] || [recipe length]!=64 ||
         [recipe rangeOfCharacterFromSet:bad].location!=NSNotFound ||
         ![identity[@"schema"] isEqual:@1] ||
         ![identity[@"policy"] isEqual:@"henge_stateless_compute_dynamic_1"] ||
         ![identity[@"protocol"] isEqual:@"embedded-close-v1"])
        return;
      HGEmbeddedRecipe=[recipe copy]; HGRecipeID=HGEmbeddedRecipe.UTF8String;
      HGRoot=[[[NSSearchPathForDirectoriesInDomains(NSCachesDirectory,NSUserDomainMask,YES) firstObject]
          stringByAppendingPathComponent:@"Henge/Stateless"] stringByAppendingPathComponent:HGEmbeddedRecipe];
#ifdef HG_ALLOW_NATIVE_TESTING
      const char *testCache=getenv("HENGE_EMBEDDED_TEST_CACHE");
      if(testCache) HGRoot=[@(testCache) stringByAppendingPathComponent:HGEmbeddedRecipe];
#endif
      HGTimeout=60; HGEmbeddedTransport=YES; HGConfiguration=[identity copy];
      return;
    }
    NSData *bytes =
        [NSData dataWithContentsOfFile:[@(path) stringByExpandingTildeInPath]];
    NSDictionary *c = bytes ? [NSJSONSerialization JSONObjectWithData:bytes
                                                              options:0
                                                                error:nil]
                            : nil;
    if (![c isKindOfClass:NSDictionary.class] || [c[@"schema"] intValue] != 1 ||
        ![c[@"enabled"] boolValue] ||
        ![c[@"recipe_sha256"] isEqual:@(HGRecipeID)]) {
      fprintf(stderr,
              "henge-dynamic: disabled: invalid configuration or recipe\n");
      return;
    }
    NSURL *url = [NSURL URLWithString:c[@"endpoint"]];
    if (!url.host.length ||
        (![url.scheme isEqual:@"http"] && ![url.scheme isEqual:@"https"]) ||
        url.user || url.password || url.query || url.fragment) {
      fprintf(stderr, "henge-dynamic: disabled: invalid endpoint\n");
      return;
    }
    NSString *tokenPath = [c[@"token_file"] stringByExpandingTildeInPath];
    NSString *token = [[NSString stringWithContentsOfFile:tokenPath
                                                 encoding:NSUTF8StringEncoding
                                                    error:nil]
        stringByTrimmingCharactersInSet:NSCharacterSet
                                            .whitespaceAndNewlineCharacterSet];
    NSRegularExpression *pattern = [NSRegularExpression
        regularExpressionWithPattern:@"^[A-Za-z0-9_-]{32,128}$"
                             options:0
                               error:nil];
    if (!token ||
        [pattern numberOfMatchesInString:token
                                 options:0
                                   range:NSMakeRange(0, token.length)] != 1) {
      fprintf(stderr,
              "henge-dynamic: disabled: missing or invalid token file\n");
      return;
    }
    NSString *cache = [c[@"cache_directory"] stringByExpandingTildeInPath];
    if (!cache.isAbsolutePath) {
      fprintf(stderr, "henge-dynamic: disabled: cache path must be absolute\n");
      return;
    }
    HGToken = [token copy];
    HGEndpoint = [url.absoluteString
        stringByTrimmingCharactersInSet:
            [NSCharacterSet characterSetWithCharactersInString:@"/"]];
    HGTimeout = fmin(60, fmax(1, [c[@"timeout_seconds"] doubleValue] ?: 45));
    HGRoot = [[cache stringByStandardizingPath]
        stringByAppendingPathComponent:@(HGRecipeID)];
    HGConfiguration = [c copy];
  });
  return HGConfiguration != nil;
}
static NSData *HGHTTP(NSString *method, NSString *suffix, NSData *body,
                      NSTimeInterval seconds, NSInteger *status,
                      NSError **error) {
  NSMutableURLRequest *request = [NSMutableURLRequest
       requestWithURL:[NSURL URLWithString:[HGEndpoint
                                               stringByAppendingString:suffix]]
          cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
      timeoutInterval:fmax(.1, seconds)];
  request.HTTPMethod = method;
  request.HTTPBody = body;
  if(HGToken) [request setValue:[@"Bearer " stringByAppendingString:HGToken]
      forHTTPHeaderField:@"Authorization"];
  NSURLSessionConfiguration *cfg =
      NSURLSessionConfiguration.ephemeralSessionConfiguration;
  cfg.timeoutIntervalForRequest = fmax(.1, seconds);
  cfg.timeoutIntervalForResource = fmax(.1, seconds);
  cfg.HTTPShouldSetCookies = NO;
  NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg];
  dispatch_semaphore_t sem = dispatch_semaphore_create(0);
  __block NSData *result = nil;
  __block NSError *failure = nil;
  __block NSInteger code = 0;
  NSURLSessionDataTask *task = [session
      dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *e) {
          result = data;
          failure = e;
          code = [(NSHTTPURLResponse *)response statusCode];
          dispatch_semaphore_signal(sem);
        }];
  [task resume];
  if (dispatch_semaphore_wait(
          sem, dispatch_time(DISPATCH_TIME_NOW,
                             (int64_t)((seconds + .25) * NSEC_PER_SEC)))) {
    [task cancel];
    [session invalidateAndCancel];
    if (status)
      *status = 0;
    if (error)
      *error = [NSError
          errorWithDomain:@"HengeDynamicTransport"
                     code:1
                 userInfo:@{
                   NSLocalizedDescriptionKey : @"Compiler request timed out"
                 }];
    return nil;
  }
  [session invalidateAndCancel];
  if (status)
    *status = code;
  if (error)
    *error = failure;
  return result;
}
static BOOL HGFetchEmbedded(NSString *key, NSData *request, NSString *base, NSDate *deadline, NSError **error) {
  while(deadline.timeIntervalSinceNow>0) {
    NSInteger status=0;
    NSData *data=HGHTTP(@"POST",[@"/close/" stringByAppendingString:key],request,
        fmin(60,deadline.timeIntervalSinceNow),&status,error);
    if(status==429 || status==0) { [NSThread sleepForTimeInterval:.1]; continue; }
    if(!data || status!=200 || data.length>(24u<<20)) {
      HGFail(error,42,@"Embedded compiler request unavailable or oversized"); return NO;
    }
    NSDictionary *receipt=[NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if(![receipt isKindOfClass:NSDictionary.class] || ![receipt[@"schema"] isEqual:@1] ||
       ![receipt[@"recipe"] isEqual:@(HGRecipeID)] || ![receipt[@"request_sha256"] isEqual:key]) {
      HGFail(error,34,@"Embedded compiler receipt identity mismatch"); return NO;
    }
    if([receipt[@"status"] isEqual:@"rejected"]) {
      if(![receipt[@"error"] isKindOfClass:NSString.class]) { HGFail(error,44,@"Invalid rejection receipt"); return NO; }
      return [data writeToFile:[base stringByAppendingString:@".json"] options:NSDataWritingAtomic error:error];
    }
    if(![receipt[@"status"] isEqual:@"ready"] || ![receipt[@"output_base64"] isKindOfClass:NSString.class] ||
       ![receipt[@"output_bytes"] isKindOfClass:NSNumber.class]) {
      HGFail(error,44,@"Invalid embedded compiler receipt"); return NO;
    }
    NSData *binary=[[NSData alloc] initWithBase64EncodedString:receipt[@"output_base64"] options:0];
    if(binary.length<88 || binary.length>(16u<<20) ||
       binary.length!=[receipt[@"output_bytes"] unsignedLongLongValue] ||
       ![HGSHA(binary) isEqual:receipt[@"output_sha256"]]) {
      HGFail(error,34,@"Embedded compiler output digest or length mismatch"); return NO;
    }
    NSMutableDictionary *compact=[receipt mutableCopy]; [compact removeObjectForKey:@"output_base64"];
    NSData *record=[NSJSONSerialization dataWithJSONObject:compact options:NSJSONWritingSortedKeys error:error];
    return record && [binary writeToFile:[base stringByAppendingString:@".metallib"] options:NSDataWritingAtomic error:error] &&
        [record writeToFile:[base stringByAppendingString:@".json"] options:NSDataWritingAtomic error:error];
  }
  HGFail(error,33,@"Embedded compiler did not complete before the deadline"); return NO;
}
static BOOL HGFetchReady(NSString *key, NSData *request, NSString *base,
                         NSError **error) {
  // Per-request lock also coordinates independent opted-in application
  // processes.
  NSString *lockPath = [base stringByAppendingString:@".lock"];
  int fd = open(lockPath.fileSystemRepresentation, O_CREAT | O_RDWR | O_CLOEXEC,
                0600);
  if (fd < 0) {
    HGFail(error, 40, @"Cannot lock compiler cache entry");
    return NO;
  }
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:HGTimeout];
  BOOL locked = NO, ok = NO;
  while (deadline.timeIntervalSinceNow > 0) {
    if (flock(fd, LOCK_EX | LOCK_NB) == 0) {
      locked = YES;
      break;
    }
    [NSThread sleepForTimeInterval:.05];
  }
  if (!locked) {
    close(fd);
    HGFail(error, 41, @"Compiler cache lock timed out");
    return NO;
  }
  NSString *receiptPath = [base stringByAppendingString:@".json"];
  if ([NSFileManager.defaultManager fileExistsAtPath:receiptPath]) {
    ok = YES;
    goto done;
  }
  if(HGEmbeddedTransport) { ok=HGFetchEmbedded(key,request,base,deadline,error); goto done; }
  {
    NSInteger status = 0;
    NSError *network = nil;
    NSData *ack =
        HGHTTP(@"POST", [@"/v1/requests/" stringByAppendingString:key], request,
               fmin(10, deadline.timeIntervalSinceNow), &status, &network);
    if (!ack || status < 200 || status >= 300) {
      HGFail(error, 42,
             [NSString
                 stringWithFormat:@"Compiler submission failed (HTTP %ld): %@",
                                  (long)status,
                                  network.localizedDescription
                                      ?: @"request rejected"]);
      goto done;
    }
    while (deadline.timeIntervalSinceNow > 0) {
      NSData *reply = HGHTTP(
          @"GET", [NSString stringWithFormat:@"/v1/ready/%@.json", key], nil,
          fmin(5, deadline.timeIntervalSinceNow), &status, &network);
      if (status == 404) {
        [NSThread sleepForTimeInterval:.1];
        continue;
      }
      if (!reply || status != 200 || reply.length > 65536) {
        HGFail(error, 43, @"Compiler receipt unavailable or oversized");
        goto done;
      }
      NSDictionary *receipt = [NSJSONSerialization JSONObjectWithData:reply
                                                              options:0
                                                                error:nil];
      if (![receipt[@"request_sha256"] isEqual:key] ||
          ![receipt[@"recipe"] isEqual:@(HGRecipeID)]) {
        HGFail(error, 34, @"Compiler receipt identity mismatch");
        goto done;
      }
      if ([receipt[@"status"] isEqual:@"rejected"]) {
        [reply writeToFile:receiptPath options:NSDataWritingAtomic error:nil];
        ok = YES;
        goto done;
      }
      if (![receipt[@"status"] isEqual:@"ready"]) {
        HGFail(error, 44, @"Unknown compiler receipt status");
        goto done;
      }
      NSData *binary = HGHTTP(
          @"GET", [NSString stringWithFormat:@"/v1/ready/%@.metallib", key],
          nil, fmin(10, deadline.timeIntervalSinceNow), &status, &network);
      if (!binary || status != 200 || binary.length > 16 * 1024 * 1024 ||
          binary.length != [receipt[@"output_bytes"] unsignedLongLongValue] ||
          ![HGSHA(binary) isEqual:receipt[@"output_sha256"]]) {
        HGFail(error, 34, @"Compiler output digest or length mismatch");
        goto done;
      }
      if (![binary writeToFile:[base stringByAppendingString:@".metallib"]
                       options:NSDataWritingAtomic
                         error:error] ||
          ![reply writeToFile:receiptPath
                      options:NSDataWritingAtomic
                        error:error])
        goto done;
      ok = YES;
      goto done;
    }
    HGFail(error, 33,
           @"Compiler did not complete before the configured deadline");
  }
done:
  flock(fd, LOCK_UN);
  close(fd);
  return ok;
}
