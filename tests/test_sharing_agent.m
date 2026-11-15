/* Execute the production companion HTTP parser and ordered retry queue. No guest or pasteboard access. */
#import <AppKit/AppKit.h>
#include <pthread.h>
#include <assert.h>
static unsigned short test_port;
#define HOST "127.0.0.1"
#define HENGE_SHARE_PORT test_port
#define main henge_agent_entrypoint
#include "../tools/henge-agent.m"
#undef main
static int listener_fd;
static NSMutableArray<NSData *> *uploads;
static void *server(void *unused) {
    (void)unused;
    for(unsigned i=0;i<5;i++) { @autoreleasepool {
        int fd=accept(listener_fd,NULL,NULL);assert(fd>=0);
        NSMutableData *bytes=[NSMutableData data];NSRange end;
        size_t expected=0;
        for(;;) {
            char buf[4096];ssize_t n=recv(fd,buf,sizeof buf,0);assert(n>0);
            [bytes appendBytes:buf length:(NSUInteger)n];
            end=[bytes rangeOfData:[NSData dataWithBytes:"\r\n\r\n" length:4] options:0 range:NSMakeRange(0,bytes.length)];
            if(end.location==NSNotFound)continue;
            NSString *head=[[NSString alloc]initWithData:[bytes subdataWithRange:NSMakeRange(0,end.location)]encoding:NSUTF8StringEncoding];
            NSRange at=[head rangeOfString:@"Content-Length: "];
            assert(at.location!=NSNotFound);expected=strtoul(head.UTF8String+NSMaxRange(at),NULL,10);
            if(bytes.length>=NSMaxRange(end)+expected)break;
        }
        [uploads addObject:[bytes subdataWithRange:NSMakeRange(NSMaxRange(end),expected)]];
        const char *response=i==1?"HTTP/1.1 200 OK\r\nContent-Length: 9\r\n\r\nab":
                             i==2?"HTTP/1.1 200 OK\r\n\r\nabc":
                                  "HTTP/1.1 204 No Content\r\nContent-Length: 0\r\nX-Henge-Seq: 3\r\n\r\n";
        if(i!=3)assert(!send_all(fd,response,strlen(response)));
        close(fd);
    }}
    return NULL;
}
static void drain(void) {
    NSDate *until=[NSDate dateWithTimeIntervalSinceNow:5];
    while(sendingClipboard && until.timeIntervalSinceNow>0)
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    assert(!sendingClipboard);
}
int main(void) { @autoreleasepool {
    alarm(20);uploads=[NSMutableArray new];
    listener_fd=socket(AF_INET,SOCK_STREAM,0);assert(listener_fd>=0);
    struct sockaddr_in addr={.sin_family=AF_INET,.sin_addr.s_addr=htonl(INADDR_LOOPBACK)};
    assert(!bind(listener_fd,(struct sockaddr *)&addr,sizeof addr));
    socklen_t size=sizeof addr;assert(!getsockname(listener_fd,(struct sockaddr *)&addr,&size));test_port=ntohs(addr.sin_port);
    assert(!listen(listener_fd,8));pthread_t thread;assert(!pthread_create(&thread,NULL,server,NULL));
    int status=0;unsigned long seq=0;
    NSData *unicode=[@"line1\n🐈 café" dataUsingEncoding:NSUTF8StringEncoding];
    assert(request(@"PUT",@"/.henge/clipboard",unicode,&status,&seq) && status==204 && seq==3);
    assert(!request(@"GET",@"/.henge/clipboard",nil,&status,NULL)); /* truncated */
    assert(!request(@"GET",@"/.henge/clipboard",nil,&status,NULL)); /* missing framing */
    clipboardUploadQueue=dispatch_queue_create("test.clipboard.upload",DISPATCH_QUEUE_SERIAL);
    pendingClipboard=[@"old" dataUsingEncoding:NSUTF8StringEncoding];pendingRevision=1;
    uploadClipboard();drain();assert(pendingClipboard && clipboardFailures==1 && retryClipboardAt>0);
    pendingClipboard=[@"newest" dataUsingEncoding:NSUTF8StringEncoding];pendingRevision++;
    retryClipboardAt=0;uploadClipboard();drain();assert(!pendingClipboard && !clipboardFailures);
    pthread_join(thread,NULL);close(listener_fd);
    assert([uploads[0]isEqual:unicode]);
    assert([uploads[3]isEqual:[@"old"dataUsingEncoding:NSUTF8StringEncoding]]);
    assert([uploads[4]isEqual:[@"newest"dataUsingEncoding:NSUTF8StringEncoding]]);
    puts("Sharing companion: UTF-8, complete framing, truncated response rejection, failure retention and newest retry passed");
} return 0; }
