"""Execute production clipboard publication/notification under concurrent updates.
Only the HTTP body/response are fixtures; locks, ownership and callbacks are real.
"""
from pathlib import Path
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'host/share.c').read_text()
clipboard = source[source.index('static pthread_mutex_t clip_mu'):source.index('/* ---- connections ---- */')]
start = source.index('static int clipboard_get(')
end = source.index('\nstatic int serve_henge(', start)
fixture = r'''
#define _POSIX_C_SOURCE 200809L
#include <assert.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <sys/time.h>
#include <errno.h>
#define SMALL_BODY_MAX (16 * 1024 * 1024)
typedef struct Conn { const char *text; } Conn;
typedef struct Request { char query[128]; } Request;
static int body_discard(Conn *c, Request *r) { (void)c;(void)r;return 0; }
static unsigned long response_seq;
static int response_code;
static int respond(Conn *c, Request *r, int code, const char *reason, const char *headers, const void *text, size_t len) {
    (void)c;(void)r;(void)reason;(void)text;(void)len;response_code=code;
    assert(sscanf(headers,"X-Henge-Seq: %lu",&response_seq)==1);return 0;
}
static char *body_small(Conn *c, Request *r, size_t *len) {
    (void)r; *len = strlen(c->text); return strdup(c->text);
}
static int respond_empty(Conn *c, Request *r, int code, const char *reason) {
    (void)c; (void)r; assert((code == 204 && !strcmp(reason, "No Content")) || code == 400); return 0;
}
CLIPBOARD
PUT
static _Atomic unsigned calls;
static void consume(void) {
    atomic_fetch_add(&calls, 1);
    // Reentry must be safe: callbacks run after releasing clip_mu.
    free(hv_share_take_clipboard());
    hv_share_set_clipboard("device response");
}
static void put(const char *text) { Conn c = {text}; Request r = {0}; assert(!clipboard_put(&c, &r)); }
static void *writer(void *unused) {
    (void)unused;
    for (int i=0; i<1000; ++i) put("concurrent guest clipboard");
    return NULL;
}
int main(void) {
    assert(!hv_share_clipboard_ready());
    Conn handshake = {""}; Request hr = {.query="since=0&ack=1&initial=1"};
    assert(!clipboard_get(&handshake,&hr) && response_code==204 && !hv_share_clipboard_ready());
    unsigned long handshake_seq=hv_share_publish_clipboard("first delivery");
    strcpy(hr.query,"since=0&ack=1");
    assert(!clipboard_get(&handshake,&hr) && response_code==200 && response_seq==handshake_seq && hv_share_clipboard_ready());
    strcpy(hr.query,"since=0");
    assert(!clipboard_get(&handshake,&hr) && !hv_share_clipboard_ready());
    assert(!hv_share_publish_clipboard(NULL));
    unsigned long a = hv_share_publish_clipboard("Unicode 🐈 / line1\nline2");
    assert(a && !hv_share_clipboard_delivered(a));
    Conn ack = {"invalid"}; Request ar = {0}; assert(!clipboard_ack(&ack,&ar));
    assert(!hv_share_clipboard_delivered(a));
    char number[32]; snprintf(number,sizeof number,"%lu",a); ack.text=number;
    assert(!clipboard_ack(&ack,&ar)); assert(hv_share_clipboard_delivered(a));
    unsigned long b = hv_share_publish_clipboard("new paste"); assert(b != a);
    assert(!hv_share_clipboard_delivered(a) && !hv_share_clipboard_delivered(b));
    assert(!clipboard_ack(&ack,&ar)); assert(!hv_share_clipboard_delivered(b));
    snprintf(number,sizeof number,"%lu",b); assert(!clipboard_ack(&ack,&ar));
    assert(hv_share_clipboard_delivered(b));
    put("pending before registration"); assert(atomic_load(&calls)==0);
    hv_share_set_clipboard_notify(consume); assert(atomic_load(&calls)==1);
    assert(!hv_share_take_clipboard());
    hv_share_set_clipboard("device update"); assert(atomic_load(&calls)==1);
    put("guest update"); assert(atomic_load(&calls)==2);
    hv_share_set_clipboard_notify(NULL);
    put("keep until next visible session"); assert(atomic_load(&calls)==2);
    char *text=hv_share_take_clipboard(); assert(text && !strcmp(text,"keep until next visible session")); free(text);
    hv_share_set_clipboard_notify(consume); assert(atomic_load(&calls)==2);
    pthread_t workers[4];
    for(int i=0;i<4;++i) assert(!pthread_create(&workers[i],NULL,writer,NULL));
    for(int i=0;i<4;++i) assert(!pthread_join(workers[i],NULL));
    assert(atomic_load(&calls)==4002); assert(!hv_share_take_clipboard());
    hv_share_set_clipboard_notify(NULL); free(device_clip);
    puts("clipboard notifications: pending catchup, removal, reentry, 4000 concurrent updates passed");
}
'''.replace('CLIPBOARD', clipboard).replace('PUT', source[start:end])
with tempfile.TemporaryDirectory(prefix='henge-clipboard-') as folder:
    path = Path(folder)
    (path/'test.c').write_text(fixture)
    subprocess.run([os.environ.get('CC','cc'),'-std=c11','-Wall','-Wextra','-Werror','-g','-O1',
                    '-fsanitize=address,undefined','-pthread',str(path/'test.c'),'-o',str(path/'check')],check=True)
    subprocess.run([str(path/'check')],check=True,timeout=20)
