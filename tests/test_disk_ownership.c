#include "machine.h"
#include "disk.h"
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/wait.h>
#include <unistd.h>

int hv_knob[HV_K_COUNT];
static int failures;
static void check(const char *name, int ok) { printf("%s: %s\n",ok?"ok":"FAIL",name); failures+=!ok; }
static int can_lock(const char *path, int mode) {
    int fd=open(path,O_RDWR);
    if(fd<0)return 0;
    int result=flock(fd,mode|LOCK_NB)==0;
    close(fd); return result;
}
int main(int argc,char **argv) {
    if(argc==4 && !strcmp(argv[1],"--closed-after-exec"))
        return !(fcntl(atoi(argv[2]),F_GETFD)<0 && errno==EBADF &&
                 fcntl(atoi(argv[3]),F_GETFD)<0 && errno==EBADF);
    char path[]="/tmp/henge-disk-owner-XXXXXX",alias[128];
    int fd=mkstemp(path); if(fd<0)return 2;
    if(ftruncate(fd,4096))return 2;
    close(fd); snprintf(alias,sizeof alias,"%s-alias",path);
    if(link(path,alias))return 2;
    HvDisk disk={.fd=-1,.wfd=-1},other={.fd=-1,.wfd=-1};
    check("writer opens",hv_disk_open(&disk,path,0,0)==0);
    check("provisioner blocked by writer",!can_lock(alias,LOCK_EX));
    check("read-only attach blocked by writer",!can_lock(alias,LOCK_SH));
    check("second VM writer denied through alias",hv_disk_open(&other,alias,0,0)<0 && other.fd==-1);
    check("read-only VM denied while writer lives",hv_disk_open(&other,alias,0,1)<0 && other.fd==-1);
    pid_t pid=fork();
    if(pid<0)return 2;
    if(pid==0) { hv_disk_close(&disk); _exit(can_lock(alias,LOCK_EX)?1:0); }
    int status=0;waitpid(pid,&status,0);
    check("parent retains lock after child closes inherited descriptors",WIFEXITED(status)&&!WEXITSTATUS(status));
    hv_disk_close(&disk);
    check("close releases image",can_lock(alias,LOCK_EX));
    check("readonly opens",hv_disk_open(&disk,path,0,1)==0);
    check("concurrent readonly opens",hv_disk_open(&other,alias,0,1)==0);
    check("readonly owners exclude provisioning",!can_lock(path,LOCK_EX));
    hv_disk_close(&other);hv_disk_close(&disk);
    fd=open(path,O_RDWR);if(fd<0||flock(fd,LOCK_EX|LOCK_NB))return 2;
    check("provisioner excludes VM boot",hv_disk_open(&disk,alias,0,0)<0 && disk.fd==-1);
    close(fd);
    check("failed invalid-offset open releases ownership",hv_disk_open(&disk,path,8192,0)<0 && can_lock(path,LOCK_EX));
    setenv("HV_WRITE_CACHE","0",1);
    check("uncached writer opens",hv_disk_open(&disk,path,0,0)==0);
    check("alternate writer is active",disk.wfd>=0);
    check("uncached writer retains ownership",!can_lock(alias,LOCK_EX));
    char mainfd[16],writefd[16];
    snprintf(mainfd,sizeof mainfd,"%d",disk.fd);snprintf(writefd,sizeof writefd,"%d",disk.wfd);
    pid=fork();
    if(pid<0)return 2;
    if(pid==0) {execl(argv[0],argv[0],"--closed-after-exec",mainfd,writefd,(char *)NULL);_exit(127);}
    waitpid(pid,&status,0);
    check("executed helpers cannot retain image descriptors",WIFEXITED(status)&&!WEXITSTATUS(status));
    const char marker[]="disk ownership";char readback[sizeof marker]={0};
    check("alternate writer readback",hv_disk_write(&disk,0,marker,sizeof marker)==0 &&
        hv_disk_read(&disk,0,readback,sizeof readback)==0 && !memcmp(marker,readback,sizeof marker));
    hv_disk_close(&disk);unsetenv("HV_WRITE_CACHE");
    check("uncached writer close releases ownership",can_lock(path,LOCK_EX));
    unlink(alias);unlink(path);
    printf("Disk ownership: %d failures\n",failures);return failures!=0;
}
