#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
mkdir -p build/portable
${CC:-cc} -std=c11 -D_DEFAULT_SOURCE -D_POSIX_C_SOURCE=200809L -DF_BARRIERFSYNC=10300 -DF_NOCACHE=48 \
    -Wall -Wextra -O1 -g -ffunction-sections -fdata-sections \
    -fsanitize=address,undefined -fno-omit-frame-pointer \
    -Icore -Ihost -Idevices tests/test_disk_io.c host/disk.c \
    -Wl,--gc-sections -Wl,--wrap=pread -Wl,--wrap=pwrite \
    -o build/portable/test_disk_io
build/portable/test_disk_io
