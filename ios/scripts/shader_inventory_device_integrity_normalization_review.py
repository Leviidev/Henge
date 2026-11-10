#!/usr/bin/env python3
"""Independent bilinear CPU oracle for derived normalization consumers."""
from collections import Counter
import hashlib
import struct


def expected_pixels(normalized):
    colors=[(1.0,0.0,0.0,1.0),(0.0,1.0,0.0,1.0),(0.0,0.0,1.0,1.0),(1.0,1.0,1.0,1.0)]
    result=[]
    for coordinate in (0.125,0.375,0.625,0.875):
        position=max(0.0,min(3.0,(coordinate*4 if normalized else coordinate)-0.5));lower=int(position);upper=min(3,lower+1);weight=position-lower
        result.extend(colors[lower][c]*(1-weight)+colors[upper][c]*weight for c in range(4))
    return result


def review(report):
    issues=[]
    def check(value,reason):
        if not value:issues.append(reason)
    check(report.get('library_loaded') and report.get('names')==['normalization_probe'],'derived executable not loaded with expected entrypoint')
    constants=report.get('constants',[]);check(len(constants)==1 and constants[0].get('name')=='coreimage::_texture2D_is_normalized' and constants[0].get('index')==64999 and constants[0].get('type')==53 and constants[0].get('required'),'required normalization bool contract missing')
    cases=report.get('cases',[]);check(Counter(c.get('normalized') for c in cases)==Counter([0,1]),'specialization matrix missing/duplicated')
    for c in cases:
        mode=c.get('normalized')
        if mode not in (0,1):continue
        pixels=expected_pixels(mode);digest=hashlib.sha256(struct.pack('<16f',*pixels)).hexdigest();check(c.get('function_created') and c.get('pipeline_created') and c.get('dispatch_completed'),'specialized pipeline/dispatch failed');check(c.get('actual_float4_pixels')==pixels and c.get('actual_sha256')==digest,'CPU bilinear texture oracle failed')
    return {'status':'derived_AIR_normalization_oracle_exact_CI_reflection_unverified' if not issues else 'failed_or_incomplete','issues':issues,'pixels_checked':8 if not issues else None,'float_components_checked':32 if not issues else None,'CI_archive_reflection_semantics_verified':False,'limits':['Consumer is an authored Metal wrapper statically linked to extracted AIR and the same original float CI stdlib.','Both inputs are normalized to a common Mac target before linking; this does not exercise raw archive CoreImage argument/reflection binding or iPad behavior.']}
