#include "HGGuestClone.h"
#include "HGGuestMedia.h"
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/clonefile.h>
#include <unistd.h>

static int named_clone(const HGGuestClone *clone) {
    struct stat named;
    return clone->created && clone->directory_fd>=0 &&
        !fstatat(clone->directory_fd,clone->name,&named,AT_SYMLINK_NOFOLLOW) &&
        S_ISREG(named.st_mode) && named.st_dev==clone->created_identity.st_dev &&
        named.st_ino==clone->created_identity.st_ino;
}

int hg_guest_clone_discard(HGGuestClone *clone,const char **error) {
    if (!clone || !error) return -1;
    if (clone->created) {
        if (!named_clone(clone)) { *error="clone-path-identity-changed";return -1; }
        if (clone->disk.fd>=0) {
            // Discard may follow authorized changes to the private copy. Refresh
            // only the inventory query's timestamp/size anchor; inode ownership
            // remains bound to the original created inode and held descriptor.
            HGGuestDisk current=clone->disk;
            if (fstat(current.fd,&current.identity) ||
                current.identity.st_dev!=clone->created_identity.st_dev ||
                current.identity.st_ino!=clone->created_identity.st_ino) {
                *error="clone-cleanup-required";return -1;
            }
            char *media=NULL;
            int status=hg_guest_media_copy(&current,&media,error);
            int empty=!status && media && !strcmp(media,"[]");
            free(media);
            if (!empty) { *error="clone-media-cleanup-required";return -1; }
        }
        if (unlinkat(clone->directory_fd,clone->name,0)) {
            *error="clone-cleanup-required";return -1;
        }
        clone->created=0;
    }
    if (clone->directory_fd>=0 && fsync(clone->directory_fd)) {
        *error="clone-directory-sync";return -1;
    }
    hg_guest_disk_close(&clone->disk);
    if (clone->directory_fd>=0) close(clone->directory_fd);
    *clone=(HGGuestClone)HG_GUEST_CLONE_INIT;
    *error=NULL;return 0;
}

int hg_guest_clone_create(const HGGuestDisk *source,int parent_fd,
                          HGGuestClone *clone,const char **error) {
    if (!source || !clone || !error) return -1;
    if (clone->source || clone->directory_fd>=0 || clone->disk.fd>=0 || clone->created) {
        *error="clone-already-open";return -1;
    }
    *error="clone-parent";
    struct stat parent;
    int directory=fcntl(parent_fd,F_DUPFD_CLOEXEC,3);
    if (directory<0) return -1;
    if (fstat(directory,&parent) || !S_ISDIR(parent.st_mode) ||
        parent.st_uid!=geteuid() || (parent.st_mode&0077)) { close(directory);return -1; }
    if (!hg_guest_disk_unchanged(source)) { close(directory);*error="image-identity-changed";return -1; }
    clone->source=source;clone->directory_fd=directory;
    for (unsigned int attempt=0;attempt<8;attempt++) {
        uint64_t random;
        arc4random_buf(&random,sizeof(random));
        snprintf(clone->name,sizeof(clone->name),"henge-clone-%016llx.img",(unsigned long long)random);
        if (!fclonefileat(source->fd,directory,clone->name,CLONE_NOOWNERCOPY)) {
            clone->created=1;break;
        }
        if (errno!=EEXIST || attempt==7) {
            *error="clone-unavailable";goto fail;
        }
    }
    if (fstatat(directory,clone->name,&clone->created_identity,AT_SYMLINK_NOFOLLOW)) {
        *error="clone-identity";goto fail;
    }
    int incoming=openat(directory,clone->name,O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC);
    struct stat opened;
    if (incoming<0 || fstat(incoming,&opened) || opened.st_dev!=clone->created_identity.st_dev ||
        opened.st_ino!=clone->created_identity.st_ino) {
        if (incoming>=0) close(incoming);
        *error="clone-open";goto fail;
    }
    struct stat *made=&clone->created_identity;
    if (!S_ISREG(made->st_mode) || made->st_nlink!=1 || made->st_uid!=geteuid() ||
        (made->st_dev==source->identity.st_dev && made->st_ino==source->identity.st_ino) ||
        made->st_size!=source->identity.st_size || fchmod(incoming,0600)) {
        close(incoming);*error="clone-identity";goto fail;
    }
    int status=hg_guest_disk_inspect_fd(incoming,&clone->disk,error);
    close(incoming);
    if (status) goto fail;
    if (clone->disk.identity.st_dev!=made->st_dev || clone->disk.identity.st_ino!=made->st_ino ||
        clone->disk.first_apfs_lba!=source->first_apfs_lba ||
        clone->disk.last_apfs_lba!=source->last_apfs_lba ||
        memcmp(clone->disk.disk_uuid,source->disk_uuid,16) || !named_clone(clone) ||
        !hg_guest_disk_unchanged(source)) { *error="clone-identity";goto fail; }
    if (fsync(clone->disk.fd) || fsync(directory)) { *error="clone-sync";goto fail; }
    *error=NULL;return 0;
fail: {
    const char *failure=*error;
    const char *cleanup=NULL;
    if (hg_guest_clone_discard(clone,&cleanup)) *error=cleanup;
    else *error=failure;
    return -1;
}
}
