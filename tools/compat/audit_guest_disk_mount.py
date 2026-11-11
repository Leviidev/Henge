#!/usr/bin/env python3
"""On-iPad offline-provisioning control using an explicitly authored scratch image.

This is a developer qualification tool, not Henge's automatic provisioning path.
It never accepts a VM-sized image and never reformats or mounts the running guest.
"""
import argparse
import ctypes as c
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import stat
import subprocess
import tempfile
import uuid


def media(names):
    io = c.CDLL('/System/Library/Frameworks/IOKit.framework/IOKit')
    cf = c.CDLL('/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation')
    signatures = [
        (io, 'IOServiceMatching', [c.c_char_p], c.c_void_p),
        (io, 'IOServiceGetMatchingServices', [c.c_uint, c.c_void_p, c.POINTER(c.c_uint)], c.c_int),
        (io, 'IOIteratorNext', [c.c_uint], c.c_uint),
        (io, 'IOObjectRelease', [c.c_uint], c.c_int),
        (io, 'IORegistryEntryCreateCFProperties', [c.c_uint, c.POINTER(c.c_void_p), c.c_void_p, c.c_uint], c.c_int),
        (io, 'IORegistryEntrySearchCFProperty', [c.c_uint, c.c_char_p, c.c_void_p, c.c_void_p, c.c_uint], c.c_void_p),
        (cf, 'CFStringCreateWithCString', [c.c_void_p, c.c_char_p, c.c_uint], c.c_void_p),
        (cf, 'CFPropertyListCreateData', [c.c_void_p, c.c_void_p, c.c_long, c.c_ulong, c.c_void_p], c.c_void_p),
        (cf, 'CFDataGetLength', [c.c_void_p], c.c_long),
        (cf, 'CFDataGetBytePtr', [c.c_void_p], c.c_void_p),
        (cf, 'CFRelease', [c.c_void_p], None),
    ]
    for library, name, arguments, result in signatures:
        function = getattr(library, name)
        function.argtypes, function.restype = arguments, result

    def decode(value):
        data = cf.CFPropertyListCreateData(None, value, 100, 0, None)
        if not data:
            raise ValueError('Could not encode registry property')
        try:
            return plistlib.loads(c.string_at(cf.CFDataGetBytePtr(data), cf.CFDataGetLength(data)))
        finally:
            cf.CFRelease(data)

    iterator = c.c_uint()
    code = io.IOServiceGetMatchingServices(0, io.IOServiceMatching(b'IOMedia'), c.byref(iterator))
    if code:
        raise OSError('IOMedia enumeration failed: ' + hex(code & 0xffffffff))
    result = {}
    try:
        while entry := io.IOIteratorNext(iterator):
            try:
                value = c.c_void_p()
                code = io.IORegistryEntryCreateCFProperties(entry, c.byref(value), None, 0)
                if code:
                    continue
                try:
                    properties = decode(value.value)
                finally:
                    cf.CFRelease(value.value)
                name = properties.get('BSD Name')
                if name not in names:
                    continue
                key = cf.CFStringCreateWithCString(None, b'image-path', 0x08000100)
                try:
                    path = io.IORegistryEntrySearchCFProperty(entry, b'IOService', key, None, 3)
                finally:
                    cf.CFRelease(key)
                if not path:
                    raise ValueError('Selected media has no disk-image ancestor')
                try:
                    image = decode(path)
                finally:
                    cf.CFRelease(path)
                image = os.fsdecode(image.rstrip(b'\0')) if isinstance(image, bytes) else image
                result[name] = {key: properties.get(key) for key in ('Content', 'Size', 'Writable', 'Whole', 'Leaf')}
                result[name]['image'] = str(Path(image).resolve(strict=True))
            finally:
                io.IOObjectRelease(entry)
    finally:
        io.IOObjectRelease(iterator)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('scratch_image', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if os.geteuid() != 0:
        parser.error('Run the developer control as root on the test iPad')
    if args.output.exists():
        parser.error('Choose a new report path')
    image = args.scratch_image.resolve(strict=True)
    if not image.name.startswith('henge-provision-audit-') or image.suffix != '.dmg':
        parser.error('Only explicitly named authored scratch fixtures are accepted')
    fd = os.open(image, os.O_RDWR | os.O_NOFOLLOW | os.O_CLOEXEC)
    mountpoint = None
    physical = None
    mounted = False
    attachment_attempted = False
    report = dict(schema=1, passed=False, scope='authored 96 MiB APFS image only; no guest or app bootstrap qualification',
                  source_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(), commands=[])

    def run(command):
        result = subprocess.run(command, capture_output=True, text=True, timeout=45)
        report['commands'].append(dict(command=command, exit=result.returncode,
                                       stdout=result.stdout[:8192], stderr=result.stderr[:8192]))
        result.check_returncode()
        return result.stdout

    try:
        identity = os.fstat(fd)
        if not stat.S_ISREG(identity.st_mode) or identity.st_size != 96 << 20 or os.pread(fd, 8, 512) != b'EFI PART':
            raise ValueError('Expected a newly authored 96 MiB GPT disk fixture')
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        report['exclusive_lock_held'] = True
        attachment_attempted = True
        output = run(['/usr/sbin/hdik', '-nomount', '-drivekey', 'write-protected=false', str(image)])
        entries = re.findall(r'^(/dev/disk\d+(?:s\d+)*)\s+(\S+)', output, re.M)
        roots = [path for path, kind in entries if kind == 'GUID_partition_scheme']
        volumes = [path for path, kind in entries if kind.startswith('41504653-')]
        if len(roots) != 1 or len(volumes) != 1:
            raise ValueError('Expected one physical scratch device and one APFS volume')
        physical = roots[0]
        names = {path.removeprefix('/dev/') for path, _ in entries}
        actual = media(names)
        if set(actual) != names or any(item['image'] != str(image) or not item['Writable'] for item in actual.values()):
            raise ValueError('Media ancestry or writable attachment mismatch')
        if actual[physical.removeprefix('/dev/')]['Size'] != identity.st_size:
            raise ValueError('Physical attachment size mismatch')
        if (os.stat(image).st_dev, os.stat(image).st_ino) != (identity.st_dev, identity.st_ino):
            raise ValueError('Scratch pathname changed during attachment')
        report['media'] = actual
        mountpoint = Path(tempfile.mkdtemp(prefix='henge-provision-audit-', dir='/private/var/mnt'))
        run(['/sbin/mount_apfs', '-o', 'nobrowse,noexec,nosuid', volumes[0], str(mountpoint)])
        mounted = True
        if os.stat(mountpoint).st_dev == os.stat(mountpoint.parent).st_dev or os.statvfs(mountpoint).f_flag & os.ST_RDONLY:
            raise ValueError('Writable scratch mount was not observed')
        marker = mountpoint / ('henge-audit-' + uuid.uuid4().hex + '.txt')
        payload = b'Henge offline provisioning scratch control\n'
        marker_fd = os.open(marker, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o644)
        try:
            if os.write(marker_fd, payload) != len(payload):
                raise OSError('Incomplete scratch marker write')
            os.fsync(marker_fd)
        finally:
            os.close(marker_fd)
        run(['/sbin/umount', str(mountpoint)])
        mounted = False
        run(['/sbin/mount_apfs', '-o', 'rdonly,nobrowse,noexec,nosuid', volumes[0], str(mountpoint)])
        mounted = True
        if not os.statvfs(mountpoint).f_flag & os.ST_RDONLY or marker.read_bytes() != payload:
            raise ValueError('Read-only remount did not preserve the marker')
        report.update(passed=True, marker_roundtrip=True, readonly_remount=True,
                      marker_sha256=hashlib.sha256(payload).hexdigest())
    except Exception as error:
        report['error'] = str(error)
    finally:
        try:
            if mounted:
                run(['/sbin/umount', str(mountpoint)])
            if physical:
                run(['/usr/sbin/hdik', '-e', physical])
            elif attachment_attempted:
                raise RuntimeError('Attachment identity unavailable; inspect owned media before reusing the fixture')
            if mountpoint:
                mountpoint.rmdir()
            report['cleanup_complete'] = True
        except Exception as error:
            report.update(passed=False, cleanup_complete=False, cleanup_error=str(error))
        os.close(fd)
        args.output.write_text(json.dumps(report, indent=2) + '\n')
        print(json.dumps(report, indent=2))
    if not report['passed']:
        raise SystemExit(1)


if __name__ == '__main__':
    main()
