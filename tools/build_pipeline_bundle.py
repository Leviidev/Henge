#!/usr/bin/env python3
"""Build Henge's known display pipelines offline; never embeds guest/game data.

Metal's translator validates each requested architecture/platform. Runtime opens
only a matching architecture/OS archive and retains ordinary compilation on a
miss. --plan-only permits deterministic configuration tests without Xcode.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile


def configuration(library):
    names = ('screen_v', 'screen_plain', 'screen_linear', 'screen_cursor')
    functions = [{'label': name, 'library': 'lib:screen', 'name': name} for name in names]
    pipelines = []
    for fragment in names[1:]:
        cursor = fragment == 'screen_cursor'
        color = dict(pixel_format='BGRA8Unorm', write_mask='All',
                     blending_state='Enabled' if cursor else 'Disabled',
                     alpha_blend_operation='Add', rgb_blend_operation='Add',
                     source_alpha_blend_factor='One', source_rgb_blend_factor='One',
                     destination_alpha_blend_factor='OneMinusSourceAlpha' if cursor else 'Zero',
                     destination_rgb_blend_factor='OneMinusSourceAlpha' if cursor else 'Zero')
        pipelines.append(dict(vertex_function_descriptor='fnd:screen_v',
                              fragment_function_descriptor='fnd:' + fragment,
                              raster_sample_count=1, color_attachments=[color]))
    return dict(libraries=[dict(label='screen', path=str(Path(library).resolve()))],
                function_descriptors=dict(library_function_descriptors=functions),
                pipeline_descriptors=dict(render_pipeline_descriptors=pipelines))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', required=True, type=Path)
    parser.add_argument('--platform', choices=('ios', 'macos'), default='ios')
    parser.add_argument('--gpu', default='applegpu_g16g,applegpu_g19p',
                        help='Compiler architecture names; runtime still checks the actual device')
    parser.add_argument('--os-min', default='27.0')
    parser.add_argument('--plan-only', action='store_true')
    args = parser.parse_args()
    gpus = list(dict.fromkeys(args.gpu.split(',')))
    if not gpus or any(not g.startswith('applegpu_g') or not g.replace('_', '').isalnum() for g in gpus):
        parser.error('Expected explicit Metal GPU architecture names')
    out = args.out.resolve(); out.mkdir(parents=True, exist_ok=True)
    library = out / 'screen.metallib'
    config = configuration(library)
    (out / 'screen.mtl4-json').write_text(json.dumps(config, sort_keys=True, indent=2) + '\n')
    if args.plan_only:
        print('PASS offline pipeline plan:', len(config['pipeline_descriptors']['render_pipeline_descriptors']), 'pipelines;', ','.join(gpus))
        return
    sdk = 'iphoneos' if args.platform == 'ios' else 'macosx'
    source = Path(__file__).resolve().parents[1] / 'devices/pvg_screen.metal'
    tool = subprocess.check_output(['xcrun', '-sdk', sdk, 'metal-tt', '-version'], text=True, stderr=subprocess.STDOUT).strip()
    inputs = hashlib.sha256(source.read_bytes() + json.dumps(dict(configuration=config, gpus=gpus,
                            platform=args.platform, os=args.os_min, tool=tool), sort_keys=True).encode()).hexdigest()
    stamp = out / 'inputs.sha256'
    if stamp.is_file() and stamp.read_text().strip() == inputs:
        old = json.loads((out / 'index.json').read_text())
        files = [old['screen_library'], *old['archives']]
        if all((out/f['file']).is_file() and hashlib.sha256((out/f['file']).read_bytes()).hexdigest() == f['sha256'] for f in files):
            print('PASS existing exact offline pipeline bundle:', inputs)
            return
    with tempfile.TemporaryDirectory(prefix='henge-pipelines-', dir=out) as temporary:
        air = Path(temporary) / 'screen.air'
        minimum = '-mios-version-min=26.0' if args.platform == 'ios' else '-mmacosx-version-min=26.0'
        subprocess.run(['xcrun', '-sdk', sdk, 'metal', '-std=metal4.0', minimum,
                        '-c', str(source), '-o', str(air)], check=True)
        subprocess.run(['xcrun', '-sdk', sdk, 'metallib', str(air), '-o', str(library)], check=True)
        entries = []
        for gpu in gpus:
            path = out / (gpu + '.mtl4a')
            partial = Path(temporary) / path.name
            subprocess.run(['xcrun', '-sdk', sdk, 'metal-tt', '-arch', gpu,
                            f'-{args.platform}-version-min', args.os_min,
                            str(out/'screen.mtl4-json'), '-o', str(partial)], check=True)
            if partial.stat().st_size < 256:
                raise RuntimeError('Compiler produced an empty pipeline archive')
            partial.replace(path)
            entries.append(dict(file=path.name, gpu=gpu, platform=args.platform,
                                os_major=int(args.os_min.split('.')[0]),
                                sha256=hashlib.sha256(path.read_bytes()).hexdigest()))
    manifest = dict(schema=1, toolchain=tool, inputs_sha256=inputs,
                    screen_library=dict(file=library.name, sha256=hashlib.sha256(library.read_bytes()).hexdigest()),
                    archives=entries)
    (out/'index.json').write_text(json.dumps(manifest, sort_keys=True, indent=2)+'\n')
    stamp.write_text(inputs+'\n')
    print('PASS compiled offline pipeline bundle:', len(entries), 'GPU architectures;', tool)


if __name__ == '__main__':
    main()
