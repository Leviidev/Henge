#include "share.h"
#include <assert.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

static char socket_path[108];
static void http(const char *query, const char *body, char *out) {
    int fd = socket(AF_UNIX, SOCK_STREAM, 0); assert(fd >= 0);
    struct sockaddr_un address = {.sun_family = AF_UNIX};
    snprintf(address.sun_path, sizeof address.sun_path, "%s", socket_path);
    assert(connect(fd, (struct sockaddr *)&address, sizeof address) == 0);
    char request[1024]; int n = snprintf(request, sizeof request,
        "%s /.henge/runner?%s HTTP/1.1\r\nHost: 10.0.2.4\r\nConnection: close\r\nContent-Length: %zu\r\n\r\n%s",
        body ? "PUT" : "GET", query, body ? strlen(body) : 0, body ? body : "");
    assert(write(fd, request, (size_t)n) == n);
    size_t at = 0; ssize_t got;
    while ((got = read(fd, out+at, 4095-at)) > 0) { at += (size_t)got; assert(at < 4095); }
    out[at] = 0; close(fd);
}
int main(void) {
    alarm(15);
    char folder[] = "/tmp/henge-runner-XXXXXX"; assert(mkdtemp(folder));
    snprintf(socket_path, sizeof socket_path, "%s/s", folder);
    assert(hv_share_start(folder, socket_path, NULL) == 0);
    char response[4096];
    http("since=0",NULL,response);
    assert(strstr(response,"200 OK") && strstr(response,"\"action\":\"stop\""));
    assert(strstr(response,"X-Henge-Seq: 18446744073709551615"));
    http("since=18446744073709551615",NULL,response);assert(strstr(response,"410 Gone"));
    http("seq=1","2",response);assert(strstr(response,"410 Gone"));
    http("seq=1","{\"action\":\"start\"}",response);assert(strstr(response,"410 Gone"));
    unlink(socket_path); rmdir(folder);
    puts("retired runner: legacy stop migration, no active command/status route or long-poll passed");
}
