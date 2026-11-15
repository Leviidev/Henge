#include "disk_resize.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
int main(int argc,char **argv){
 if(argc!=3)return 2;
 char error[512]={0};unsigned partition=0;int rc;
 HvDiskExpansionInfo info={0};
 if(!strcmp(argv[2],"inspect")||!strcmp(argv[2],"prepare")){
  rc=!strcmp(argv[2],"inspect")?hv_disk_expansion_info(argv[1],&info,error,sizeof error):hv_disk_prepare_apfs(argv[1],&info,error,sizeof error);
  if(!rc)printf("%llu %llu %llu %llu %u %u %u\n",(unsigned long long)info.disk_bytes,(unsigned long long)info.apfs_bytes,(unsigned long long)info.contiguous_bytes,(unsigned long long)info.recovery_bytes,info.apfs_partition,info.recovery_partition,info.can_prepare);
 }else{
  rc=hv_disk_expand(argv[1],strtoull(argv[2],NULL,10),&partition,error,sizeof error);
  if(!rc)printf("%u\n",partition);
 }
 if(rc)fprintf(stderr,"%s\n",error);
 return rc?1:0;
}
