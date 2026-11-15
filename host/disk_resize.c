#ifdef __APPLE__
#define _DARWIN_C_SOURCE 1
#else
#define _POSIX_C_SOURCE 200809L
#endif
#include "disk_resize.h"
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <sys/statvfs.h>
#include <unistd.h>
#ifdef __APPLE__
#include <sys/clonefile.h>
#endif

static uint32_t get32(const unsigned char *p){return (uint32_t)p[0]|(uint32_t)p[1]<<8|(uint32_t)p[2]<<16|(uint32_t)p[3]<<24;}
static uint64_t get64(const unsigned char *p){return get32(p)|(uint64_t)get32(p+4)<<32;}
static void put32(unsigned char *p,uint32_t v){for(int i=0;i<4;i++)p[i]=(unsigned char)(v>>(8*i));}
static void put64(unsigned char *p,uint64_t v){put32(p,(uint32_t)v);put32(p+4,(uint32_t)(v>>32));}
static uint32_t crc(const void *data,size_t count){const unsigned char *p=data;uint32_t value=~0u;while(count--){value^=*p++;for(int i=0;i<8;i++)value=(value>>1)^((0u-(value&1u))&0xedb88320u);}return ~value;}
static int transfer(int fd,void *data,size_t count,uint64_t at,int write){
 unsigned char *p=data;while(count){ssize_t n=write?pwrite(fd,p,count,(off_t)at):pread(fd,p,count,(off_t)at);if(n<0&&errno==EINTR)continue;if(n<=0)return -1;p+=n;count-=(size_t)n;at+=(uint64_t)n;}return 0;
}
static int header_valid(unsigned char *h,uint64_t here,uint64_t other){
 if(memcmp(h,"EFI PART",8)||get32(h+8)!=0x10000||get32(h+12)<92||get32(h+12)>512||get64(h+24)!=here||get64(h+32)!=other)return 0;
 uint32_t wanted=get32(h+16);put32(h+16,0);uint32_t actual=crc(h,get32(h+12));put32(h+16,wanted);return actual==wanted;
}
static void seal(unsigned char *h){put32(h+16,0);put32(h+16,crc(h,get32(h+12)));}
static int clone_image(const char *source,const char *destination){
#ifdef __APPLE__
 return clonefile(source,destination,0);
#elif defined(HENGE_DISK_RESIZE_TEST)
 /* Test-only filesystem boundary on Linux; GPT/atomic replacement is production code. */
 int a=open(source,O_RDONLY),b=open(destination,O_CREAT|O_EXCL|O_WRONLY,0600);if(a<0||b<0){if(a>=0)close(a);if(b>=0)close(b);return -1;}
 unsigned char buf[65536];ssize_t n;int rc=0;while((n=read(a,buf,sizeof buf))>0)if(transfer(b,buf,(size_t)n,(uint64_t)lseek(b,0,SEEK_CUR),1)||lseek(b,n,SEEK_CUR)<0){rc=-1;break;}if(n<0)rc=-1;close(a);close(b);return rc;
#else
 (void)source;(void)destination;errno=ENOTSUP;return -1;
#endif
}
/* Recovery containers use partition-relative APFS block addresses. Validate a
   real checksummed NX superblock before offering to move one; unknown layouts
   stay untouched. Data is copied verbatim and verified before changing GPT. */
static int recovery_valid(int fd,uint64_t start,uint64_t sectors) {
 unsigned char first[4096];
 if(transfer(fd,first,sizeof first,start*512,0)||memcmp(first+32,"NXSB",4))return 0;
 uint32_t size=get32(first+36);uint64_t blocks=get64(first+40);
 if(size<4096||size>65536||(size&(size-1))||!blocks||blocks>sectors/(size/512))return 0;
 unsigned char *data=malloc(size);if(!data)return 0;
 if(transfer(fd,data,size,start*512,0)){free(data);return 0;}
 uint64_t a=0,b=0,mod=0xffffffffu;
 for(uint32_t i=8;i<size;i+=4){a=(a+get32(data+i))%mod;b=(b+a)%mod;}
 uint64_t low=mod-((a+b)%mod),high=mod-((a+low)%mod);
 int valid=get64(data)==(low|(high<<32));free(data);return valid;
}
static int copy_verified(int from,int to,uint64_t start,uint64_t destination,uint64_t bytes) {
 size_t chunk=1024*1024;unsigned char *a=malloc(chunk),*b=malloc(chunk);
 if(!a||!b){free(a);free(b);return -1;}
 int rc=0;
 while(bytes){size_t n=bytes<chunk?(size_t)bytes:chunk;
  if(transfer(from,a,n,start,0)||transfer(to,a,n,destination,1)||transfer(to,b,n,destination,0)||memcmp(a,b,n)){rc=-1;break;}
  start+=n;destination+=n;bytes-=n;
 }
 free(a);free(b);return rc;
}
/* mode: expand raw image, prepare existing capacity, inspect read-only. */
static int disk_transform(const char *path,uint64_t bytes,unsigned *last_apfs,HvDiskExpansionInfo *info,int mode,char *error,size_t error_bytes){

 int source=-1,target=-1,dir=-1,rc=-1,backup_linked=0;unsigned char *entries=NULL,*secondary=NULL;
 char *temp=NULL,*backup=NULL,*parent=NULL;const char *why="Cannot expand this disk";
 unsigned char front[1024],tail[512];struct stat st;
 if(last_apfs)*last_apfs=0;
 if(info)memset(info,0,sizeof *info);
 if(!path||(!mode&&(bytes>(2ull<<40)||bytes%512))){why="Choose a whole-GB capacity up to 2048 GB";goto end;}
 size_t length=strlen(path);temp=calloc(length+64,1);backup=malloc(length+32);parent=strdup(path);
 if(!temp||!backup||!parent){why="Not enough memory to prepare disk expansion";goto end;}
 snprintf(backup,length+32,"%s%s",path,mode?".before-apfs-expansion":".before-expansion");snprintf(temp,length+64,"%s.growing.XXXXXX",path);
 source=open(path,(mode==2?O_RDONLY:O_RDWR)|O_NOFOLLOW);if(source<0||flock(source,LOCK_EX|LOCK_NB)){why="The disk is busy or unavailable; fully shut down the Mac first";goto end;}
 if(fstat(source,&st)||!S_ISREG(st.st_mode)||st.st_size<34*512||st.st_size%512||(!mode&&bytes<=(uint64_t)st.st_size)){why="Expansion must be larger than the current raw disk; shrinking is not supported";goto end;}
 if(mode)bytes=(uint64_t)st.st_size;
 uint64_t old_last=(uint64_t)st.st_size/512-1,new_last=bytes/512-1;
 if(transfer(source,front,sizeof front,0,0)||transfer(source,tail,512,old_last*512,0)||!header_valid(front+512,1,old_last)||!header_valid(tail,old_last,1)){why="The disk GPT needs repair in macOS before it can be expanded safely";goto end;}
 if(front[510]!=0x55||front[511]!=0xaa){why="The protective partition map is invalid";goto end;}
 int protective=-1;for(int i=0;i<4;i++){unsigned char type=front[446+i*16+4];if(type==0xee&&protective<0)protective=i;else if(type){why="Hybrid partition maps are not supported for expansion";goto end;}}
 if(protective<0){why="A GPT protective partition is required";goto end;}
 unsigned char *h=front+512;uint32_t count=get32(h+80),stride=get32(h+84);uint64_t total=(uint64_t)count*stride;
 if(!count||count>4096||stride<128||stride>1024||stride%8||total>1048576||get32(tail+80)!=count||get32(tail+84)!=stride||memcmp(h+56,tail+56,16)||get32(h+88)!=get32(tail+88)){why="Unsupported or inconsistent GPT partition tables";goto end;}
 uint64_t sectors=(total+511)/512,first=get64(h+40),last=get64(h+48),table=get64(h+72),old_table=get64(tail+72);
 if(table<2||table>=first||sectors>first-table||last>=old_table||old_table>=old_last||sectors>old_last-old_table||first>last||get64(tail+40)!=first||get64(tail+48)!=last){why="GPT partition-table bounds are invalid";goto end;}
 entries=malloc((size_t)total);secondary=malloc((size_t)total);if(!entries||!secondary){why="Not enough memory for the partition map";goto end;}
 if(transfer(source,entries,(size_t)total,table*512,0)||transfer(source,secondary,(size_t)total,old_table*512,0)||memcmp(entries,secondary,(size_t)total)||crc(entries,(size_t)total)!=get32(h+88)){why="The primary and backup partition tables do not match";goto end;}
 uint64_t highest=0;unsigned highest_index=0;const unsigned char zero[16]={0},apfs[16]={0xef,0x57,0x34,0x7c,0,0,0xaa,0x11,0xaa,0x11,0,0x30,0x65,0x43,0xec,0xac};
 for(uint32_t i=0;i<count;i++){const unsigned char *p=entries+(size_t)i*stride;if(!memcmp(p,zero,16))continue;uint64_t a=get64(p+32),b=get64(p+40);if(a<first||b<a||b>last){why="A partition exceeds the GPT usable range";goto end;}if(b>highest){highest=b;highest_index=i+1;}for(uint32_t j=0;j<i;j++){const unsigned char *q=entries+(size_t)j*stride;if(memcmp(q,zero,16)&&a<=get64(q+40)&&get64(q+32)<=b){why="Overlapping partitions require repair before expansion";goto end;}}}
 if(!highest_index){why="No installed partitions were found";goto end;}
 unsigned apfs_index=!memcmp(entries+(size_t)(highest_index-1)*stride,apfs,16)?highest_index:0;
 uint64_t recovery_start=0,recovery_end=0,recovery_destination=0;
 unsigned main_index=0,recovery_index=0,main_count=0;
 const unsigned char recovery_type[16]={0x72,0x76,0x63,0x52,0x00,0x79,0xaa,0x11,0xaa,0x11,0x00,0x30,0x65,0x43,0xec,0xac};
 for(uint32_t i=0;i<count;i++)if(!memcmp(entries+(size_t)i*stride,apfs,16)){main_index=i+1;main_count++;}
 HvDiskExpansionInfo found={.disk_bytes=(uint64_t)st.st_size};
 if(main_count==1){
  unsigned char *main=entries+(size_t)(main_index-1)*stride;
  uint64_t main_start=get64(main+32),main_end=get64(main+40),next=last+1;
  found.apfs_partition=main_index;found.apfs_bytes=(main_end-main_start+1)*512;
  for(uint32_t i=0;i<count;i++){
   unsigned char *p=entries+(size_t)i*stride;
   if(memcmp(p,zero,16)&&get64(p+32)>main_end&&get64(p+32)<next){next=get64(p+32);recovery_index=i+1;}
  }
  found.contiguous_bytes=(next-main_end-1)*512;
  if(recovery_index==highest_index){
   unsigned char *recovery=entries+(size_t)(recovery_index-1)*stride;
   recovery_start=get64(recovery+32);recovery_end=get64(recovery+40);
   uint64_t size=recovery_end-recovery_start+1;
   /* 1 MiB alignment; destination must be wholly beyond the old container. */
   if(last+1>=size)recovery_destination=((last+1-size)/2048)*2048;
   if(!memcmp(recovery,recovery_type,16)&&recovery_destination>recovery_end&&
      recovery_destination>main_end&&recovery_valid(source,recovery_start,size)){
    found.recovery_partition=recovery_index;found.recovery_bytes=size*512;found.can_prepare=1;
   }
  }
 }
 if(info)*info=found;
 if(mode==2){rc=0;goto end;}
 if(mode==1&&!found.can_prepare){
  if(found.apfs_partition&&found.contiguous_bytes>=1024*1024){rc=0;goto end;}
  why="No safely movable trailing APFS Recovery container was found. The disk is unchanged; inspect its layout in macOS Disk Utility";goto end;
 }
 if(access(backup,F_OK)==0){why="A previous disk backup exists. Export or remove it before changing this disk again";goto end;}
 if(mode==1){
  struct statvfs space;
  if(fstatvfs(source,&space)||!space.f_frsize||space.f_bavail<((found.recovery_bytes+(64ull<<20))/space.f_frsize)+1){why="Not enough device storage to preserve and relocate Recovery safely";goto end;}
 }
 target=mkstemp(temp);if(target<0){why="Cannot reserve a temporary image path";goto end;}close(target);target=-1;unlink(temp);
 if(clone_image(path,temp)){why="Safe filesystem cloning failed. Keep the Mac in Henge's local storage and enough storage free";goto end;}
 target=open(temp,O_RDWR|O_NOFOLLOW);if(target<0||ftruncate(target,(off_t)bytes)){why="Cannot extend the cloned sparse disk";goto end;}
 if(mode==1){
  if(copy_verified(source,target,recovery_start*512,recovery_destination*512,found.recovery_bytes)){why="Recovery copy verification failed; original disk preserved";goto end;}
  unsigned char *recovery=entries+(size_t)(recovery_index-1)*stride;
  put64(recovery+32,recovery_destination);put64(recovery+40,recovery_destination+found.recovery_bytes/512-1);
  put32(h+88,crc(entries,(size_t)total));put32(tail+88,get32(h+88));
  found.contiguous_bytes=(recovery_destination-get64(entries+(size_t)(main_index-1)*stride+40)-1)*512;
  found.can_prepare=0;if(info)*info=found;
 }
 uint64_t new_table=new_last-sectors,new_usable=new_table-1;
 put64(tail+24,new_last);put64(tail+48,new_usable);put64(tail+72,new_table);seal(tail);
 put64(h+32,new_last);put64(h+48,new_usable);seal(h);
 put32(front+446+protective*16+12,new_last>0xffffffffu?0xffffffffu:(uint32_t)new_last);
 if(transfer(target,entries,(size_t)total,table*512,1)||transfer(target,entries,(size_t)total,new_table*512,1)||transfer(target,tail,512,new_last*512,1)||transfer(target,front,sizeof front,0,1)||fsync(target)){why="Could not commit the expanded GPT; original disk preserved";goto end;}
 /* Original stays reachable even if replacement or later volume resizing fails. */
 char *slash=strrchr(parent,'/');if(slash){*slash=0;dir=open(*parent?parent:"/",O_RDONLY);}
 if(link(path,backup)){why="Cannot preserve the original disk backup";goto end;}backup_linked=1;
 if(dir>=0)(void)fsync(dir);
 if(rename(temp,path)){why="Cannot replace the original disk; original remains intact";goto end;}
 if(dir>=0)(void)fsync(dir);
 if(last_apfs)*last_apfs=apfs_index;
 rc=0;
end:
 if(rc&&backup_linked)unlink(backup);
 if(temp)unlink(temp);
 if(source>=0)close(source);
 if(target>=0)close(target);
 if(dir>=0)close(dir);
 if(rc&&error&&error_bytes)snprintf(error,error_bytes,"%s",why);
 free(entries);free(secondary);free(temp);free(backup);free(parent);return rc;
}

int hv_disk_expand(const char *path,uint64_t bytes,unsigned *last_apfs,char *error,size_t n){return disk_transform(path,bytes,last_apfs,NULL,0,error,n);}
int hv_disk_expansion_info(const char *path,HvDiskExpansionInfo *info,char *error,size_t n){return disk_transform(path,0,NULL,info,2,error,n);}
int hv_disk_prepare_apfs(const char *path,HvDiskExpansionInfo *info,char *error,size_t n){return disk_transform(path,0,NULL,info,1,error,n);}
