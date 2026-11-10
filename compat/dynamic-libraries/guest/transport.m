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
static BOOL HGLoadConfiguration(void) {
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    const char *path = getenv("HENGE_DYNAMIC_CONFIG");
    if (!path)
      return;
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
  [request setValue:[@"Bearer " stringByAppendingString:HGToken]
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
