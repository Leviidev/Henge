"""Actual production replay across fresh native processes, not an API mock."""
from pathlib import Path
import os,subprocess,tempfile
root=Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='henge-archive-') as directory:
    env={**os.environ,'HV_PVG_ARCHIVE_DIR':directory}
    subprocess.run([str(root/'build/test_pvg_lifecycle')],env=env,check=True,timeout=75)
    archives=list(Path(directory).glob('*.bin'))
    assert len(archives)>=4 and any('-14-' in p.name for p in archives) and any('-11-' in p.name for p in archives)
    assert sum(p.stat().st_size for p in archives)<=128<<20
    # An invalid artifact and stale schema are disposable cache inputs.
    (Path(directory)/'v0-obsolete.bin').write_bytes(b'obsolete')
    first=archives[0]
    oversized=first.with_name(first.stem.rsplit('-',1)[0]+'-9998.bin')
    with oversized.open('wb') as file:file.truncate(129<<20)
    bad=first.with_name(first.stem.rsplit('-',1)[0]+'-9999.bin');bad.write_bytes(b'corrupt')
    subprocess.run([str(root/'build/test_pvg_lifecycle')],env={**env,'HENGE_TEST_ARCHIVE_REOPEN':'1'},check=True,timeout=75)
    assert not oversized.exists() and not bad.exists() and not (Path(directory)/'v0-obsolete.bin').exists()
    assert sum(p.stat().st_size for p in Path(directory).glob('*.bin'))<=128<<20
print('PASS production persistent Metal archive: fresh-process hits, corrupt/stale rejection, bounded disk and normal compilation fallback')
