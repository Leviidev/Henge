/* Production packet parser, resolver loop and reply encoder; only DNS-SD is a
   deterministic fixture. No external network or Apple-private API is used. */
#define HV_DNS_TIMEOUT_MS 30
#include "../host/dns_proxy.c"
#include <assert.h>
#include <unistd.h>

int hv_knob[HV_K_COUNT];
enum Mode { ANSWER, NODATA, NXDOMAIN, START_FAIL, READ_FAIL, TIMEOUT, BAD_FD };
struct MockDNS { int fd[2]; enum Mode mode; DNSServiceQueryRecordReply callback; void *context; uint16_t type; };
static enum Mode fixture;
static atomic_int lookups, callbacks;
static uint8_t delivered[2048];
static uint32_t delivered_size;
static int delivered_to_guest;
static pthread_mutex_t output_mu = PTHREAD_MUTEX_INITIALIZER;

DNSServiceErrorType DNSServiceQueryRecord(DNSServiceRef *out, DNSServiceFlags flags, uint32_t interface,
    const char *name, uint16_t type, uint16_t cls, DNSServiceQueryRecordReply cb, void *context) {
    (void)flags; (void)interface; assert(cls == 1 && !strcmp(name, "example.com."));
    atomic_fetch_add(&lookups, 1);
    if (fixture == START_FAIL) return -1;
    struct MockDNS *r = calloc(1, sizeof *r); assert(r);
    r->mode = fixture; r->callback = cb; r->context = context; r->type = type;
    r->fd[0] = r->fd[1] = -1;
    if (fixture != BAD_FD) {
        assert(pipe(r->fd) == 0);
        if (fixture != TIMEOUT) assert(write(r->fd[1], "x", 1) == 1);
    }
    *out = r; return 0;
}
int DNSServiceRefSockFD(DNSServiceRef r) { return r->fd[0]; }
DNSServiceErrorType DNSServiceProcessResult(DNSServiceRef r) {
    char byte; assert(read(r->fd[0], &byte, 1) == 1);
    if (r->mode == READ_FAIL) return -1;
    const uint8_t address[16] = {1,2,3,4};
    int error = r->mode == NODATA ? kDNSServiceErr_NoSuchRecord : r->mode == NXDOMAIN ? kDNSServiceErr_NoSuchName : 0;
    r->callback(r, error ? 0 : kDNSServiceFlagsAdd, 0, error, "example.com.", r->type, 1,
                r->type == 28 ? 16 : 4, address, 60, r->context);
    return 0;
}
void DNSServiceRefDeallocate(DNSServiceRef r) {
    if (r->fd[0] >= 0) close(r->fd[0]);
    if (r->fd[1] >= 0) close(r->fd[1]);
    free(r);
}
static void output(const uint8_t *bytes, uint32_t length, int guest) {
    assert(length <= sizeof delivered);
    pthread_mutex_lock(&output_mu);
    memcpy(delivered, bytes, length); delivered_size = length; delivered_to_guest = guest;
    atomic_fetch_add(&callbacks, 1); pthread_mutex_unlock(&output_mu);
}
static void wait_idle(void) {
    int64_t end = now_ms() + 2000;
    while (atomic_load(&inflight)) {
        assert(now_ms() < end);
        struct timespec pause = {0, 1000000}; nanosleep(&pause, NULL);
    }
}
static unsigned query(uint8_t *p, uint16_t type, int edns) {
    memset(p, 0, 1600);
    for (int i=0;i<12;i++) p[i]=(uint8_t)i;
    p[12]=8; p[14]=0x45; p[23]=17;
    p[26]=10; p[28]=2; p[29]=15; p[30]=10; p[32]=2; p[33]=3;
    wr16(p+34,30000);wr16(p+36,53);
    uint8_t *d=p+42;wr16(d,0x1234);d[2]=1;wr16(d+4,1);
    const uint8_t name[]={7,'e','x','a','m','p','l','e',3,'c','o','m',0};
    memcpy(d+12,name,sizeof name);unsigned n=12+sizeof name;
    wr16(d+n,type);wr16(d+n+2,1);n+=4;
    if(edns){wr16(d+10,1);wr16(d+n+1,41);wr16(d+n+3,1232);n+=11;}
    wr16(p+38,8+n);wr16(p+16,20+8+n);return 42+n;
}
static void reject(uint8_t *p,unsigned n) {
    int calls=atomic_load(&lookups);assert(!hv_dns_proxy_take(p,n,output));assert(atomic_load(&lookups)==calls);
}
int main(void) {
    uint8_t p[1600];hv_knob[HV_K_DNSPROXY]=1;hv_dns_proxy_reset();
    for (int mode=ANSWER;mode<=BAD_FD;mode++) for(int aaaa=0;aaaa<2;aaaa++) {
        hv_dns_proxy_reset();fixture=(enum Mode)mode;
        unsigned n=query(p,aaaa?28:1,aaaa);int before=atomic_load(&callbacks);
        assert(hv_dns_proxy_take(p,n,output));wait_idle();assert(atomic_load(&callbacks)==before+1);
        if(mode>=START_FAIL){assert(!delivered_to_guest && delivered_size==n && !memcmp(p,delivered,n));}
        else {
            assert(delivered_to_guest && rd16(delivered+42)==0x1234 && ip_checksum(delivered+14,20)==0);
            assert(rd16(delivered+48)==(mode==ANSWER?1:0));
            assert((delivered[45]&15)==(mode==NXDOMAIN?3:0));
            assert(!memcmp(delivered,p+6,6));
        }
    }
    unsigned n=query(p,1,0);wr16(p+16,1500);reject(p,1514); // old frame-member overwrite
    n=query(p,1,0);p[14]=0x4f;reject(p,n); // header exceeds packet
    n=query(p,1,0);p[20]=0x20;reject(p,n); // fragment
    n=query(p,1,0);p[54]=0xc0;reject(p,n); // compressed question label
    n=query(p,1,1);wr16(p+n-2,65535);reject(p,n); // impossible EDNS RDLENGTH
    n=query(p,1,0);wr16(p+38,1000);reject(p,n); // UDP length outside IP
    n=query(p,1,0);atomic_store(&inflight,64);reject(p,n);atomic_store(&inflight,0);
    fixture=TIMEOUT;hv_dns_proxy_reset();
    for(int i=0;i<GIVE_UP;i++){assert(hv_dns_proxy_take(p,n,output));wait_idle();assert(!delivered_to_guest);}
    assert(!hv_dns_proxy_on() && hv_knob[HV_K_DNSPROXY]==1);reject(p,n); // atomic backoff, knob preserved
    hv_dns_proxy_reset();fixture=ANSWER;int before=atomic_load(&callbacks);
    for(int i=0;i<10;i++){assert(hv_dns_proxy_take(p,n,output));}
    wait_idle();assert(atomic_load(&callbacks)==before+10);
    hv_knob[HV_K_DNSPROXY]=0;reject(p,n);
    puts("DNS: real parser/reply/threads; A/AAAA, EDNS, NXDOMAIN/NODATA, malformed IP/UDP/DNS bounds, fallback, timeout, invalid fd, saturation and concurrent delivery passed");
}
