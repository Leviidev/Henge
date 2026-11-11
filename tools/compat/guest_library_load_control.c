/* Native build-time load control only; never shipped or run in the guest. */
#include <dlfcn.h>
#include <stdio.h>

int main(int argc, char **argv)
{
    if (argc != 3) return 64;
    for (int i = 1; i < argc; i++) {
        void *image = dlopen(argv[i], RTLD_NOW | RTLD_LOCAL);
        if (!image) {
            fprintf(stderr, "Guest library load failed: %s: %s\n", argv[i], dlerror());
            return 1;
        }
        dlclose(image);
    }
    return 0;
}
