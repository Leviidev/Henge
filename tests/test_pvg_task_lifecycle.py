#!/usr/bin/env python3
"""Compile/run the production task-lifecycle helpers, with no GPU calls.

Default source root is this script's repository parent. --source-root permits
checking another checkout. Build products live in a temporary directory.
"""
from pathlib import Path
import argparse
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--source-root', type=Path, default=Path(__file__).resolve().parents[1])
args = parser.parse_args()
root = args.source_root.resolve()
lite = (root / 'devices/pvg_lite.c').read_text()
metal = (root / 'devices/pvg_metal.m').read_text()

def function(text, marker):
    start = text.index(marker)
    opening = text.index('{', start)
    depth, end = 1, opening + 1
    while depth:
        depth += (text[end] == '{') - (text[end] == '}')
        end += 1
    return text[start:end] + '\n'

has_legacy_table = 'uint8_t legacy_object_table[512]' in lite
preamble = ('#define HV_TEST_HAS_LEGACY_TABLE %d\n' % has_legacy_table) + '''#import <Foundation/Foundation.h>
#include <stdint.h>
#include <stdlib.h>
typedef struct HvPvgLite {
 uint32_t task_root[512];
#if HV_TEST_HAS_LEGACY_TABLE
 uint8_t legacy_object_table[512];
#endif
 uint64_t task_objects[512],task_placement[512],task_generation[512];
} HvPvgLite;
'''
body = preamble
body += function(lite, 'static void task_created(')
body += function(lite, 'uint64_t hv_pvg_lite_task_generation(')
body += function(metal, 'static void task_cache_generation(')
body += function(metal, 'static BOOL task_cache_lifecycle(')
body += Path(__file__).with_name('pvg_task_lifecycle_body.m').read_text()
# The helper tests also require the production callsites; orphaned helpers
# alone must not make this suite pass.
assert lite.count('task_created(p, task,') == 2
assert 'task_cache_generation(tasks, task_generations, task, hv_pvg_lite_task_generation(lite, task));' in metal
assert 'task_cache_lifecycle(r->tasks, op, args, n)' in metal
with tempfile.TemporaryDirectory(prefix='henge-task-lifecycle-') as output:
    directory = Path(output)
    source, binary = directory / 'test.m', directory / 'test'
    source.write_text(body)
    subprocess.run(['xcrun', 'clang', '-target', 'arm64-apple-macos14',
                    '-fobjc-arc', '-Wall', '-Wextra', '-Werror', str(source),
                    '-framework', 'Foundation', '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
