#!/usr/bin/env python3
"""Compare decoded planes separately from rendered video pixels.

Exact hashes cover every recorded full frame. Numeric differences cover only
saved full-resolution frames, explicitly counted. REVIEW is not proof that the
renderer is wrong: different decoders/OS color pipelines can differ.
"""
import argparse
from fractions import Fraction
import hashlib
import json
from pathlib import Path

import numpy as np


def checked_bytes(root, name, digest, size):
    if not isinstance(name, str) or Path(name).name != name:
        raise ValueError('invalid evidence filename')
    data = (root / name).read_bytes()
    if len(data) != size or hashlib.sha256(data).hexdigest() != digest:
        raise ValueError('evidence size/hash mismatch: ' + str(root / name))
    return data


def keyed_frames(report):
    rows = {}
    for frame in report['frames']:
        key = Fraction(frame['pts_value'], frame['pts_scale'])
        if key in rows:
            raise ValueError('duplicate frame timestamp')
        rows[key] = frame
    return rows


def compare(reference, candidate):
    ref = json.loads((reference / 'result.json').read_text())
    actual = json.loads((candidate / 'result.json').read_text())
    for key in ('source_sha256', 'requested_format', 'expected_frames'):
        if ref[key] != actual[key]:
            raise ValueError('different inputs: ' + key)
    refs, frames = keyed_frames(ref), keyed_frames(actual)
    rows = []
    for timestamp in sorted(set(refs) | set(frames)):
        r, a = refs.get(timestamp), frames.get(timestamp)
        row = dict(time=str(timestamp))
        rows.append(row)
        if r is None or a is None:
            row['status'] = 'missing_frame'
            continue
        if r.get('error') or a.get('error'):
            row.update(status='frame_error', reference_error=r.get('error'), candidate_error=a.get('error'))
            continue
        if any(r[k] != a[k] for k in ('width', 'height', 'format')):
            row['status'] = 'format_or_dimensions_differ'
            continue
        expected_planes = 1 if r['format']=='BGRA' else 2 if r['format'] in ('420v','x420') else None
        if expected_planes is None or len(r['planes'])!=expected_planes or len(a['planes'])!=expected_planes:
            row['status'] = 'invalid_plane_count'
            continue
        plane_layout = lambda f: [(p['plane'], p['width'], p['height'], p['row_bytes']) for p in f['planes']]
        if plane_layout(r) != plane_layout(a):
            row['status'] = 'plane_layout_differs'
            continue
        row['decoded_planes_exact'] = all(x['sha256'] == y['sha256'] for x, y in zip(r['planes'], a['planes']))
        row['rendered_rgba_exact'] = r['rgba_sha256'] == a['rgba_sha256']
        row['status'] = 'exact_match' if row['decoded_planes_exact'] and row['rendered_rgba_exact'] else 'review'
        row['saved_frame_compared'] = False
        for root, frame in ((reference, r), (candidate, a)):
            for plane in frame['planes']:
                if plane.get('file'):
                    checked_bytes(root, plane['file'], plane['sha256'], plane['row_bytes']*plane['height'])
        if r.get('rgba_file') and a.get('rgba_file'):
            size = r['width']*r['height']*4
            rb = checked_bytes(reference, r['rgba_file'], r['rgba_sha256'], size)
            ab = checked_bytes(candidate, a['rgba_file'], a['rgba_sha256'], size)
            rp = np.frombuffer(rb, dtype=np.uint8).reshape(-1, 4)
            ap = np.frombuffer(ab, dtype=np.uint8).reshape(-1, 4)
            delta = np.abs(rp.astype(np.int16)-ap.astype(np.int16))
            row.update(saved_frame_compared=True, rgba_rmse=float(np.sqrt(np.mean(delta.astype(float)**2))),
                       max_delta=int(delta.max()), channels_over_3=int(np.count_nonzero(delta>3)),
                       alpha_exact=bool(np.array_equal(rp[:, 3], ap[:, 3])),
                       reference_rgb_nonzero=int(np.count_nonzero(rp[:, :3])), candidate_rgb_nonzero=int(np.count_nonzero(ap[:, :3])))
            if row['reference_rgb_nonzero'] and not row['candidate_rgb_nonzero']:
                row['status'] = 'blank_render'
    audio = {}
    if ref.get('audio', {}).get('bytes') and actual.get('audio', {}).get('bytes'):
        ra, aa = ref['audio'], actual['audio']
        rb = checked_bytes(reference, 'audio.f32', ra['sha256'], ra['bytes'])
        ab = checked_bytes(candidate, 'audio.f32', aa['sha256'], aa['bytes'])
        audio = dict(reference_frames=ra['frames'], candidate_frames=aa['frames'], bytes_match=len(rb)==len(ab),
                     exact_match=rb==ab, reference_error=ra.get('error'), candidate_error=aa.get('error'),
                     audible_output_tested=False)
        if len(rb)==len(ab):
            delta = np.frombuffer(rb,dtype='<f4').astype(float)-np.frombuffer(ab,dtype='<f4').astype(float)
            if not np.isfinite(delta).all():
                audio['nonfinite_samples'] = True
            else:
                audio.update(rmse=float(np.sqrt(np.mean(delta*delta))), max_delta=float(np.abs(delta).max()))
    complete = (len(rows)==ref['expected_frames'] and len(refs)==len(frames)==len(rows)
                and ref.get('session_status')==actual.get('session_status')==0
                and ref.get('reader_status')==actual.get('reader_status')==2
                and not ref['errors'] and not actual['errors'])
    return dict(status='exact_match' if complete and all(r['status']=='exact_match' for r in rows) else 'review',
                complete_frame_sets=complete, frame_count=len(rows),
                decoded_plane_matches=sum(r.get('decoded_planes_exact',False) for r in rows),
                full_rgba_hash_matches=sum(r.get('rendered_rgba_exact',False) for r in rows),
                saved_full_resolution_comparisons=sum(r.get('saved_frame_compared',False) for r in rows),
                reference_os=ref['os'], candidate_os=actual['os'],
                reference_hardware_decoder=ref.get('using_hardware_decoder'),candidate_hardware_decoder=actual.get('using_hardware_decoder'),
                reference_errors=ref['errors'],candidate_errors=actual['errors'],
                reference_player=ref.get('avplayer'),candidate_player=actual.get('avplayer'),audio=audio,frames=rows)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('reference', type=Path)
    parser.add_argument('candidate', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    result = compare(args.reference, args.candidate)
    args.output.write_text(json.dumps(result, indent=2)+'\n')
    print(json.dumps({k: v for k, v in result.items() if k not in ('frames','reference_player','candidate_player')}, indent=2))
