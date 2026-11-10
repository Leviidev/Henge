#!/usr/bin/env python3
"""Source-generated protocol3 converter/peer control, with no GPU or guest calls."""
import base64
import hashlib
import json
from pathlib import Path
import re
import subprocess
import tempfile
import unittest
from gl_position_lower import get_plan
from shader_companion_profiled import compile_request
from shader_compiler_peer_profiled import Peer
from shader_profile import verify_receipt

HERE = Path(__file__).resolve().parent
SOURCE = '''#include <metal_stdlib>
using namespace metal;
struct Out { float2 uv; float4 position [[position]]; float preserved_w; };
struct Params { float z; float w; };
vertex Out authored_vertex(uint vid [[vertex_id]], constant Params &p [[buffer(0)]]) {
 const float2 xy[3]={float2(-1,-1),float2(3,-1),float2(-1,3)};
 Out o;o.uv=float2(.25,.75);o.position=float4(xy[vid]*p.w,p.z,p.w);o.preserved_w=p.w;return o;
}
'''


def run(command):
    result = subprocess.run(command, capture_output=True, text=True, timeout=30)
    if result.returncode:
        raise RuntimeError(result.stderr)


@unittest.skipUnless((HERE / 'gl-position-plan').is_file(), 'build the optional LLVM planner first')
class AuthoredProfile(unittest.TestCase):
    def test_generated_contract_conversion_publish_and_tamper(self):
        with tempfile.TemporaryDirectory(prefix='henge-profile-authored-') as temporary:
            root = Path(temporary)
            source = root / 'vertex.metal'
            source.write_text(SOURCE)
            air, text = root / 'vertex.air', root / 'vertex.ll'
            target = 'air64_v26-apple-macosx14.0.0'
            run(['xcrun', '--sdk', 'macosx', 'metal', '-c', str(source), '-target', target, '-o', str(air)])
            run(['xcrun', '--sdk', 'macosx', 'metal', '-x', 'ir', '-S', '-emit-llvm', str(air),
                 '-target', target, '-o', str(text)])
            original = text.read_text()
            self.assertFalse(get_plan(text)['gl_clip_zero_to_one'])
            node = re.search(r'!air.language_version = !\{!(\d+)\}', original)[1]
            contract, count = re.subn(r'^!' + node + r' = .*$',
                '!' + node + ' = !{!"OpenGL GLSL", i32 1, i32 0, i32 0}', original, flags=re.M)
            self.assertEqual(count, 1)
            # Explicit authored ABI/coordinate-contract fixture, not a captured GLSL frontend output.
            text.write_text(contract)
            run(['xcrun', '--sdk', 'macosx', 'metal', '-x', 'ir', '-c', str(text),
                 '-target', target, '-o', str(air)])
            library = root / 'authored.metallib'
            run(['xcrun', '--sdk', 'macosx', 'metallib', str(air), '-o', str(library)])
            data = library.read_bytes()
            digest = hashlib.sha256(data).hexdigest()
            recipe = 'b' * 64  # Unit-only identity; never published outside this temporary directory.
            documents = root / 'documents'
            documents.mkdir()
            peer = Peer(documents, recipe)
            try:
                (documents / ('sonoma-guestlib-' + digest + '.metallib')).write_bytes(data)
                request = dict(protocol=3, target='air64-apple-ios17.0.0', sha256=digest,
                    recipe=recipe, owner=peer.owner, request='00000000-0000-4000-8000-000000000001')
                (peer.requests / (digest + '.json')).write_text(json.dumps(request))
                command = dict(request, source=base64.b64encode(data).decode())
                compiled = compile_request(command, root / 'compiler-cache', recipe)
                output = compiled['output']
                publication = dict(op='publish', sha256=digest, request=request['request'],
                    output=base64.b64encode(output).decode(), output_sha256=hashlib.sha256(output).hexdigest(),
                    transformation_profile=compiled['transformation_profile'])
                peer.publish(publication)
                receipt_path = peer.cache / (digest + '.json')
                receipt = json.loads(receipt_path.read_text())
                profile = verify_receipt(receipt, digest, recipe, output)
                self.assertTrue(profile['gl_clip_zero_to_one'])
                self.assertEqual(profile['vertex_functions'], ['authored_vertex'])
                self.assertFalse(peer.handle(dict(op='poll'))['requests'])
                self.assertEqual(compile_request(command, root / 'compiler-cache', recipe), compiled)
                receipt['transformation_profile']['binding_sha256'] = '0' * 64
                receipt_path.write_text(json.dumps(receipt))
                self.assertEqual(len(peer.handle(dict(op='poll'))['requests']), 1)
            finally:
                peer.close()


if __name__ == '__main__':
    unittest.main()
