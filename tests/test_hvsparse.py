"""Run the production image converter against disposable files and aliases."""
from pathlib import Path
import os, subprocess, tempfile
root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='henge-sparse-regression-') as tmp:
    p = Path(tmp); exe = p/'hvsparse'
    subprocess.run([os.environ.get('CC','cc'), '-D_GNU_SOURCE', '-std=c11', '-O2', '-Wall', '-Wextra', '-Werror',
                    '-I'+str(root/'host'), str(root/'host/hvsparse.c'), str(root/'tools/hvsparse_main.c'), '-o', str(exe)], check=True)
    raw=p/'raw'; packed=p/'packed'; restored=p/'restored'
    with raw.open('wb') as f:
        f.write(b'first data'); f.seek(32*1024*1024-9); f.write(b'last data')
    subprocess.run([str(exe),'pack',str(raw),str(packed)],check=True)
    subprocess.run([str(exe),'unpack',str(packed),str(restored)],check=True)
    assert raw.read_bytes()==restored.read_bytes()
    for op in ('pack','unpack'):
        for alias in ('same','hardlink','symlink'):
            src=p/(op+'-'+alias); src.write_bytes(packed.read_bytes() if op=='unpack' else b'preserve input'*256)
            before=src.read_bytes(); dst=src if alias=='same' else src.with_suffix('.alias')
            if alias=='hardlink': os.link(src,dst)
            if alias=='symlink': dst.symlink_to(src)
            assert subprocess.run([str(exe),op,str(src),str(dst)],timeout=10).returncode != 0
            assert src.read_bytes()==before
    # Invalid input must not destroy an existing, unrelated destination either.
    bad=p/'invalid'; bad.write_bytes(b'not an image'); dest=p/'existing'; dest.write_bytes(b'keep destination')
    assert subprocess.run([str(exe),'unpack',str(bad),str(dest)]).returncode != 0
    assert dest.read_bytes()==b'keep destination'
print('hvsparse: sparse round trip; six same-file/hardlink/symlink overwrite refusals; invalid input preserves existing output')
