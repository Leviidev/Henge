#!/usr/bin/env python3
"""Generate authored provider controls from source; no captured Apple libraries."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess

SOURCES = {
    'ordinary': '''#include <metal_stdlib>
using namespace metal;
constant uint multiplier [[function_constant(0)]];
kernel void ordinary(device uint *out [[buffer(0)]], uint i [[thread_position_in_grid]]) {
    out[i] = i * multiplier + 19;
}
''',
    'authored_vertex': '''#include <metal_stdlib>
using namespace metal;
vertex float4 authored_vertex(uint i [[vertex_id]]) {
    const float2 xy[3] = {float2(-1,-1), float2(3,-1), float2(-1,3)};
    return float4(xy[i], 0.25, 1);
}
''',
    'authored_fragment': '''#include <metal_stdlib>
using namespace metal;
fragment float4 authored_fragment() { return float4(0.25, 0.5, 0.75, 1); }
''',
}


def run(command):
    subprocess.run(command, check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    target = 'air64_v26-apple-macosx14.0.0'
    manifest = {'scope': 'authored ABI/coordinate controls; not captured GLSL frontend output',
                'target': target, 'assets': {}}
    for name, source in SOURCES.items():
        path = args.output / (name + '.metal')
        air = path.with_suffix('.air')
        path.write_text(source)
        run(['xcrun', '--sdk', 'macosx', 'metal', '-c', str(path),
             '-target', target, '-o', str(air)])
        if name == 'authored_vertex':
            text = path.with_suffix('.ll')
            run(['xcrun', '--sdk', 'macosx', 'metal', '-x', 'ir', '-S', '-emit-llvm',
                 str(air), '-target', target, '-o', str(text)])
            original = text.read_text()
            node = re.search(r'!air.language_version = !\{!(\d+)\}', original)
            if not node:
                raise ValueError('Missing authored language metadata')
            contract, count = re.subn(r'^!' + node[1] + r' = .*$',
                '!' + node[1] + ' = !{!"OpenGL GLSL", i32 1, i32 0, i32 0}',
                original, flags=re.M)
            if count != 1:
                raise ValueError('Ambiguous authored language metadata')
            text.write_text(contract)
            run(['xcrun', '--sdk', 'macosx', 'metal', '-x', 'ir', '-c', str(text),
                 '-target', target, '-o', str(air)])
        library = args.output / (name + '_source.metallib')
        run(['xcrun', '--sdk', 'macosx', 'metallib', str(air), '-o', str(library)])
        manifest['assets'][library.name] = hashlib.sha256(library.read_bytes()).hexdigest()
    (args.output / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')


if __name__ == '__main__':
    main()
