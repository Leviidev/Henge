#include "HGGuestCodeIdentity.h"
#include <CommonCrypto/CommonDigest.h>
#include <errno.h>
#include <fcntl.h>
#include <mach-o/loader.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static uint32_t be32(const unsigned char *p) {
    return (uint32_t)p[0]<<24|(uint32_t)p[1]<<16|(uint32_t)p[2]<<8|p[3];
}
static uint64_t be64(const unsigned char *p) { return (uint64_t)be32(p)<<32|be32(p+4); }
static int read_at(int fd,void *buffer,size_t n,uint64_t off) {
    unsigned char *p=buffer;
    while(n) {
        ssize_t r=pread(fd,p,n,(off_t)off);
        if(r<0 && errno==EINTR)continue;
        if(r<=0)return -1;
        p+=r;n-=(size_t)r;off+=(uint64_t)r;
    }
    return 0;
}
static int unchanged(int fd,const struct stat *before) {
    struct stat s;
    return !fstat(fd,&s) && s.st_dev==before->st_dev && s.st_ino==before->st_ino && s.st_size==before->st_size &&
        s.st_mtimespec.tv_sec==before->st_mtimespec.tv_sec && s.st_mtimespec.tv_nsec==before->st_mtimespec.tv_nsec &&
        s.st_ctimespec.tv_sec==before->st_ctimespec.tv_sec && s.st_ctimespec.tv_nsec==before->st_ctimespec.tv_nsec;
}
static int pages(int fd,const unsigned char *p,uint32_t len,uint32_t code_limit,const char **error) {
    uint32_t version=be32(p+8),hash_offset=be32(p+16),special=be32(p+24),slots=be32(p+28);
    unsigned hash_size=p[36],type=p[37],bits=p[39];
    unsigned minimum=version>=0x20600?108:version>=0x20500?96:version>=0x20400?88:
                     version>=0x20300?64:version>=0x20200?52:version>=0x20100?48:44;
    *error="peer-code-directory-profile";
    if(version<0x20000 || version>0x20600 || len<minimum ||
       (bits!=12 && bits!=14) || (type!=2 && type!=3) ||
       hash_size!=(type==2?32:20) || be32(p+32)!=code_limit || !code_limit ||
       (version>=0x20100 && be32(p+44)) ||
       (version>=0x20300 && be64(p+56) && be64(p+56)!=code_limit) ||
       (version>=0x20500 && be32(p+92)) || hash_offset>len ||
       (uint64_t)special*hash_size>hash_offset || hash_offset-(uint64_t)special*hash_size<minimum ||
       (uint64_t)slots*hash_size>len-hash_offset)return -1;
    uint32_t page=1u<<bits;
    if(slots!=((uint64_t)code_limit+page-1)/page)return -1;
    unsigned char *buffer=malloc(page),hash[CC_SHA256_DIGEST_LENGTH];
    if(!buffer){*error="peer-code-allocation";return -1;}
    int result=-1;*error="peer-code-page-mismatch";
    for(uint32_t i=0;i<slots;i++) {
        uint64_t offset=(uint64_t)i*page;
        uint32_t size=code_limit-offset<page?(uint32_t)(code_limit-offset):page;
        if(read_at(fd,buffer,size,offset) || !CC_SHA256(buffer,size,hash) ||
           memcmp(hash,p+hash_offset+(uint64_t)i*hash_size,hash_size))goto done;
    }
    result=0;
done:
    free(buffer);return result;
}
int hg_guest_code_identity_matches(int fd,const unsigned char cdhash[20],const char **error) {
    if(!error || !cdhash)return -1;
    *error="peer-code-file";
    struct stat st;int flags=fcntl(fd,F_GETFL);
    if(flags<0 || (flags&O_ACCMODE)!=O_RDONLY || fstat(fd,&st) || !S_ISREG(st.st_mode) ||
       st.st_size<(off_t)sizeof(struct mach_header_64) || st.st_size>256*1024*1024)return -1;
    struct mach_header_64 header;
    if(read_at(fd,&header,sizeof(header),0) || header.magic!=MH_MAGIC_64 || header.filetype!=MH_EXECUTE ||
       !header.ncmds || header.ncmds>4096 || header.sizeofcmds>1024*1024 ||
       header.sizeofcmds<(uint64_t)header.ncmds*sizeof(struct load_command) ||
       header.sizeofcmds>(uint64_t)st.st_size-sizeof(header))return -1;
    unsigned char *commands=malloc(header.sizeofcmds),*signature=NULL;
    if(!commands){*error="peer-code-allocation";return -1;}
    int result=-1;
    if(read_at(fd,commands,header.sizeofcmds,sizeof(header)))goto done;
    uint32_t cursor=0,offset=0,size=0,signatures=0;
    for(uint32_t i=0;i<header.ncmds;i++) {
        struct load_command command;
        if(header.sizeofcmds-cursor<sizeof(command))goto done;
        memcpy(&command,commands+cursor,sizeof(command));
        if(command.cmdsize<sizeof(command) || command.cmdsize%8 || command.cmdsize>header.sizeofcmds-cursor)goto done;
        if(command.cmd==LC_CODE_SIGNATURE) {
            struct linkedit_data_command link;
            if(++signatures!=1 || command.cmdsize!=sizeof(link))goto done;
            memcpy(&link,commands+cursor,sizeof(link));offset=link.dataoff;size=link.datasize;
        }
        cursor+=command.cmdsize;
    }
    if(cursor!=header.sizeofcmds || offset<sizeof(header)+(uint64_t)header.sizeofcmds ||
       size<12 || size>4*1024*1024 || offset>(uint64_t)st.st_size || size!=(uint64_t)st.st_size-offset)goto done;
    signature=malloc(size);
    if(!signature){*error="peer-code-allocation";goto done;}
    if(read_at(fd,signature,size,offset))goto done;
    uint32_t length=be32(signature+4),count=be32(signature+8);
    if(be32(signature)!=0xfade0cc0 || length>size || length<12 ||
       !count || count>32 || count>(length-12)/8)goto done;
    /* codesign can leave reserved/nonzero bytes after replacing a signature.
     * They remain inside the bounded LC_CODE_SIGNATURE area, not CodeDirectory
     * data. Only indexed objects are parsed; every covered code page is checked. */
    uint32_t starts[32],lengths[32],types[32];
    for(uint32_t i=0;i<count;i++) {
        types[i]=be32(signature+12+i*8);starts[i]=be32(signature+16+i*8);
        if(starts[i]<12+count*8 || starts[i]>length || length-starts[i]<8)goto done;
        lengths[i]=be32(signature+starts[i]+4);
        if(lengths[i]<8 || lengths[i]>length-starts[i])goto done;
        for(uint32_t j=0;j<i;j++)if(types[i]==types[j] ||
            (starts[i]<starts[j]+lengths[j] && starts[j]<starts[i]+lengths[i]))goto done;
    }
    *error="peer-code-directory-mismatch";
    for(uint32_t i=0;i<count;i++) {
        if(types[i] && (types[i]<0x1000 || types[i]>0x1005))continue;
        const unsigned char *p=signature+starts[i];unsigned char digest[32];
        if(lengths[i]<44 || be32(p)!=0xfade0c02 || (p[37]!=2 && p[37]!=3))continue;
        if(!CC_SHA256(p,lengths[i],digest) || memcmp(digest,cdhash,20))continue;
        if(pages(fd,p,lengths[i],offset,error))goto done;
        if(!unchanged(fd,&st)){*error="peer-code-file-changed";goto done;}
        result=0;*error=NULL;goto done;
    }
done:
    free(signature);free(commands);return result;
}
