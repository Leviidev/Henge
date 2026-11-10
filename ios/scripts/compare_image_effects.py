#!/usr/bin/env python3
"""Compare core_image_audit.m output against an independent Mac reference.

Different OS implementations can differ legitimately. REVIEW is a triage
result, not proof of a driver bug; inspect images and logs before changing code.
"""
import argparse
import json
import math
from pathlib import Path


def compare(reference, candidate, threshold):
    ref = json.loads((reference / 'results.json').read_text())
    actual = json.loads((candidate / 'results.json').read_text())
    size = ref['width'] * ref['height'] * 4
    if (ref['width'], ref['height']) != (actual['width'], actual['height']):
        raise ValueError('Render dimensions differ')
    rows = []
    for item in ref['results']:
        name = item['filter']
        rp, ap = reference / (name + '.rgba'), candidate / (name + '.rgba')
        if not rp.exists() or not ap.exists():
            rows.append({'filter': name, 'status': 'missing-render'})
            continue
        r, a = rp.read_bytes(), ap.read_bytes()
        if len(r) != size or len(a) != size:
            rows.append({'filter': name, 'status': 'invalid-size'})
            continue
        diffs = [abs(x-y) for x, y in zip(r, a)]
        rmse = math.sqrt(sum(d*d for d in diffs)/size)
        ref_rgb = sum(v != 0 for i, v in enumerate(r) if i % 4 != 3)
        actual_rgb = sum(v != 0 for i, v in enumerate(a) if i % 4 != 3)
        status = 'match' if rmse <= threshold else 'review'
        if not ref_rgb:
            status = 'inconclusive-zero-reference'
        elif not actual_rgb:
            status = 'blank-output'
        rows.append({'filter': name, 'status': status, 'rmse': rmse,
                     'max_delta': max(diffs), 'changed_over_3': sum(d > 3 for d in diffs),
                     'reference_rgb_nonzero': ref_rgb, 'candidate_rgb_nonzero': actual_rgb})
    return {'reference_os': ref['os'], 'candidate_os': actual['os'],
            'reference_device': ref.get('device'), 'candidate_device': actual.get('device'),
            'threshold': threshold, 'results': rows}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('reference', type=Path)
    parser.add_argument('candidate', type=Path)
    parser.add_argument('--rmse', type=float, default=2.0)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    result = compare(args.reference, args.candidate, args.rmse)
    if args.output:
        args.output.write_text(json.dumps(result, indent=2) + '\n')
    counts = {}
    for row in result['results']:
        counts[row['status']] = counts.get(row['status'], 0) + 1
        if row['status'] != 'match':
            print(f"{row['filter']}: {row['status']} rmse={row.get('rmse', float('nan')):.3f}")
    print(json.dumps(counts, sort_keys=True))
    return int(any(row['status'] != 'match' for row in result['results']))


if __name__ == '__main__':
    raise SystemExit(main())
