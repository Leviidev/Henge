"""Execute the production archive acceptance block with controlled libtool exits."""
from pathlib import Path
import subprocess
import tempfile
root=Path(__file__).resolve().parents[1]
source=(root/'tools/build_ios_restore.sh').read_text()
block=source[source.index('rm -f "$BUILD/libhengerestore.a"'):]
with tempfile.TemporaryDirectory(prefix='henge-archive-') as folder:
    p=Path(folder)
    fixture='''set -e
BUILD="$1"
OUT="$BUILD/restore"
DEPS="$BUILD/deps"
SDKNAME=iphoneos
OBJS=()
mkdir -p "$OUT"
xcrun() {
    printf partial > "$BUILD/libhengerestore.a"
    echo 'same member name: cosmetic diagnostic'
    if [ "$2" = iphoneos ] && [ "$ARCHIVE_FAIL" = 1 ]; then echo 'archive failed' >&2; return 7; fi
}
'''+block
    script=p/'check.sh';script.write_text(fixture)
    for fail in (True,False):
        import os
        r=subprocess.run(['bash',str(script),str(p)],env={**os.environ,'ARCHIVE_FAIL':str(int(fail))},capture_output=True,text=True)
        assert (r.returncode != 0)==fail,(r.returncode,r.stdout,r.stderr)
        archive=p/'libhengerestore.a'
        assert archive.exists()!=fail
        if fail: assert 'archive failed' in r.stderr
    print('restore archive: functional failure removes partial archive; cosmetic filtering accepts success')
