/* Developer-only mobile-UID app-bundle control. Build with production
 * HengeRootHelper.m, sign the bundle with no-sandbox/persona-mgmt, and include
 * the separately signed, payload-bound production helper and its resources.
 * Requires a read-only image path argument. Never attaches, mounts or writes.
 * A jailbreak CLI launch does not qualify UIKit/TrollStore application launch. */
#import <Foundation/Foundation.h>
#include "HengeRootHelper.h"
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
int main(int argc,char **argv) {
 @autoreleasepool {
  if(argc!=2 || getuid()!=501 || geteuid()!=501) return 64;
  char *probe=henge_root_helper_probe();
  if(!probe){puts("{\"control\":\"probe-failed\"}");return 1;}
  puts(probe);free(probe);
  char *image=henge_root_helper_inspect_disk(argv[1]);
  if(!image){puts("{\"control\":\"inspection-failed\"}");return 2;}
  puts(image);free(image);return 0;
 }
}
