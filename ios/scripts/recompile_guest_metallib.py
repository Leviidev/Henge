#!/usr/bin/env python3
"""Rebuild a captured macOS guest Metal library for the iOS Metal runtime.

Henge captures guest libraries as sonoma-guestlib-<sha256>.metallib in its
Documents directory. Pass one or more captured files and an output directory;
the matching sonoma-ioslib-<sha256>.metallib files can then be copied back to
Documents. A sonoma-prefer-<sha256> marker opts each library into loading first.
"""

import argparse
import hashlib
from pathlib import Path
import subprocess
import tempfile

from catalog_metallibs import inspect_metallib


def rebuild(source: Path, destination: Path, target: str) -> Path:
    data = source.read_bytes()
    record = inspect_metallib(data)
    if (record['malformed_records'] or record.get('integrity_mismatches')
            or not record['single_payload_extraction_valid']):
        raise ValueError(f"{source}: requires a validated single-module library; use the offline audit for other formats")
    module = record['air_regions'][0]
    offset, size = module['offset'], module['size']
    payload = data[offset : offset + size]
    digest = hashlib.sha256(data).hexdigest()
    destination.mkdir(parents=True, exist_ok=True)
    output = destination / f"sonoma-ioslib-{digest}.metallib"
    # Keep a failed conversion from replacing an already usable cache entry.
    with tempfile.TemporaryDirectory(prefix="henge-air-", dir=destination) as temporary:
        air = Path(temporary) / "guest.air"
        ios_air = Path(temporary) / "ios.air"
        candidate = Path(temporary) / "converted.metallib"
        air.write_bytes(payload)
        subprocess.run(
            ["xcrun", "--sdk", "iphoneos", "metal", "-x", "ir", "-c",
             str(air), "-o", str(ios_air), "-target", target],
            check=True,
        )
        subprocess.run(
            ["xcrun", "--sdk", "iphoneos", "metallib", str(ios_air),
             "-o", str(candidate)],
            check=True,
        )
        converted = inspect_metallib(candidate.read_bytes())
        original_functions = sorted((f['name'], f['type_raw']) for f in record['functions'])
        converted_functions = sorted((f['name'], f['type_raw']) for f in converted['functions'])
        if (converted['malformed_records'] or converted.get('integrity_mismatches')
                or converted['format'] != 'metallib'
                or original_functions != converted_functions):
            raise ValueError(f"{source}: conversion failed structure or function-inventory validation")
        candidate.replace(output)
    return output


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("sources", type=Path, nargs="+")
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--target", default="air64-apple-ios17.0.0")
    args = parser.parse_args()
    for source in args.sources:
        print(rebuild(source, args.output_dir, args.target))
