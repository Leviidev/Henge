#!/usr/bin/env python3
"""Compare original/patched libsamplerate EOF on an authored 18-case matrix."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import build

HERE = Path(__file__).resolve().parent

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build', type=Path, required=True)
    parser.add_argument('--archives', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=False)
    archive = args.archives.resolve() / 'libsamplerate-0.1.9.tar.gz'
    lock = json.loads((HERE / 'inputs.lock.json').read_text())
    if build.sha(archive) != lock['archives'][archive.name]['sha256']:
        raise ValueError('Original archive hash mismatch')
    source = build.unpack(archive, out)
    build.checked(['./configure', '--disable-shared', '--enable-static',
                   '--disable-fftw', '--disable-sndfile'], source, out / 'configure.log')
    build.checked(['make', '-j4'], source, out / 'make.log')
    fixed = args.build.resolve() / 'sources/libsamplerate-0.1.9'
    receipt = json.loads((args.build / 'build-receipt.json').read_text())
    if receipt['source_lock']['archives'][archive.name] != lock['archives'][archive.name]:
        raise ValueError('Fixed build uses different source archive')
    for name, directory in [('original', source), ('fixed', fixed)]:
        build.checked(['xcrun', 'clang', '-O2', '-Wno-deprecated-declarations',
                       '-I' + str(directory / 'src'), str(HERE / 'controls/samplerate_probe.c'),
                       str(directory / 'src/.libs/libsamplerate.a'), '-lm', '-o',
                       str(out / ('probe-' + name))], out, out / (name + '-compile.log'))
    cases = [(480000, 44100, c, 0) for c in (1, 2, 4, 6)]
    cases += [(480000, 48000, c, 0) for c in (1, 2)]
    cases += [(96144, 44100, c, 0) for c in (1, 2)]
    cases += [(1024, 96000, c, 0) for c in (1, 2)]
    cases += [(48001, 32000, c, 0) for c in (1, 6)]
    cases += [(n, 44100, c, 0) for n in (101, 1025) for c in (1, 2)]
    cases += [(480000, 44100, c, 1) for c in (1, 2)]
    results = []
    for index, (frames, rate, channels, mode) in enumerate(cases):
        pcm = []
        for name in ('original', 'fixed'):
            target = out / f'{index}-{name}.f32'
            command = [str(out / ('probe-' + name)), str(frames), str(rate),
                       str(mode), str(channels), str(target)]
            subprocess.run(command, capture_output=True, check=True, timeout=10)
            pcm.append(target.read_bytes())
        before, after = pcm
        expected = frames * rate // 48000
        assert len(after) == expected * channels * 4
        common = min(len(before), len(after))
        assert before[:common] == after[:common]
        results.append({'input_frames': frames, 'output_rate': rate,
                        'channels': channels, 'mode': mode,
                        'original_frames': len(before) // channels // 4,
                        'fixed_frames': len(after) // channels // 4,
                        'expected_frames': expected, 'common_pcm_exact': True,
                        'pcm_sha256': hashlib.sha256(after).hexdigest()})
    (out / 'validation.json').write_text(json.dumps({'passed': True, 'cases': results}, indent=2) + '\n')
    print(f'{len(results)} samplerate EOF cases passed')

if __name__ == '__main__':
    main()
