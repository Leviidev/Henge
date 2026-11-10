#!/usr/bin/env python3
"""Summarize GPU failures observed in one Henge guest run.

This is a coverage report for exercised scenes, not a claim that unvisited
applications or shaders work. Pair it with screenshots from the same run.
"""

import argparse
from collections import Counter
from pathlib import Path
import re


REJECTED = re.compile(
    r"rejected render state vertex=(.*?) library=([0-9a-f]{64}:[^ ]+|unknown) "
    r"fragment=(.*?) library=([0-9a-f]{64}:[^ ]+|unknown) .*? error=(.*)"
)
SURFACE = re.compile(
    r"surface \d+: unsupported Sonoma descriptor "
    r"\(fourcc ([0-9a-f]+) list (\d+) alloc (\d+) width (\d+) height (\d+) "
    r"row (\d+) first (\d+) view (\d+)x(\d+)\)"
)
PIPELINE = re.compile(r"pvg-metal: (?:pipeline \d+ \([^)]*\)|compute pipeline \([^)]*\)|library): (.*)")
FRAME = re.compile(r"gpu_frames (\d+)")
DRAW_PIPELINE = re.compile(r"trace:  pipeline \d+ (.*?) / (.*?) -> fmt \d+")
INFO_FAILURE = re.compile(r"pvg-metal: info (\d+): .*: (no buffer|no object)")
COMPUTE_REJECTED = re.compile(r"rejected compute state function=(.*?) library=([^ ]+) error=(.*)")
COMPUTE_RETRY = re.compile(r"retried compute pipeline (.*?) with converted AIR")
COMPUTE_AUDIT = re.compile(r"compute (created|queried|completed|dispatch-failed) function=(.*?) library=([^ ]+)")
FALLBACK = re.compile(r"fallback create map \d+ (\d+x\d+) fmt (\d+)")


def classify_surface(match: re.Match[str]) -> str:
    fourcc, page_list, alloc, width, height, row, first, view_w, view_h = match.groups()
    values = list(map(int, (page_list, alloc, width, height, row, first, view_w, view_h)))
    page_list, alloc, width, height, row, first, view_w, view_h = values
    if fourcc == "00000000" and not any(values[:6]):
        return "empty descriptor"
    if view_w > width or view_h > height:
        return f"view exceeds surface ({view_w}x{view_h} over {width}x{height}, {fourcc})"
    if not page_list or not alloc or not width or not height or not row:
        return f"incomplete descriptor ({fourcc})"
    if first >= 0x4000 or row * height > alloc:
        return f"invalid layout ({fourcc})"
    return f"unsupported format or layout ({fourcc})"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("log", type=Path)
    parser.add_argument("--libraries", type=Path,
                        help="directory containing sonoma-ioslib-<sha256>.metallib files")
    parser.add_argument("--previous-log", type=Path,
                        help="compare previous rejected functions with pipelines exercised in this trace")
    args = parser.parse_args()
    rejected: Counter[tuple[str, ...]] = Counter()
    compute_rejected: Counter[tuple[str, ...]] = Counter()
    compute_retried: set[str] = set()
    compute_coverage = {stage: set() for stage in ("created", "queried", "completed", "dispatch-failed")}
    surfaces: Counter[str] = Counter()
    fallbacks: Counter[tuple[str, str]] = Counter()
    other: Counter[str] = Counter()
    pipeline_diagnostics: list[str] = []
    exercised: set[tuple[str, str]] = set()
    frame = 0
    fallback_diagnostics = False
    for line in args.log.read_text(errors="replace").splitlines():
        if "unconditional mapped fallback diagnostics enabled" in line:
            fallback_diagnostics = True
        if match := REJECTED.search(line):
            rejected[match.groups()] += 1
        if match := COMPUTE_REJECTED.search(line):
            compute_rejected[match.groups()] += 1
        if match := COMPUTE_RETRY.search(line):
            compute_retried.add(match[1])
        if match := COMPUTE_AUDIT.search(line):
            compute_coverage[match[1]].add((match[2], match[3].split(":", 1)[0]))
        if match := SURFACE.search(line):
            surfaces[classify_surface(match)] += 1
        if match := FALLBACK.search(line):
            fallbacks[match.groups()] += 1
        if "pvg-metal:" in line and "unsupported mapped view format" in line:
            other["unsupported mapped texture views"] += 1
        if "pvg-metal: command buffer:" in line:
            other["command buffer errors"] += 1
        if "pvg-metal: exception:" in line:
            other["GPU replay exceptions"] += 1
        if "pvg-metal:" in line and " skipped" in line:
            other["skipped GPU commands"] += 1
        if match := INFO_FAILURE.search(line):
            other[f"object query {match[1]}: {match[2]}"] += 1
        if "pvg-metal: heap size query: no buffer" in line:
            other["heap size query: no buffer"] += 1
        if "pvg-metal:" in line and " not done" in line:
            other["unimplemented GPU descriptions"] += 1
        if match := PIPELINE.search(line):
            pipeline_diagnostics.append(match[1])
        if match := FRAME.search(line):
            frame = max(frame, int(match[1]))
        if match := DRAW_PIPELINE.search(line):
            exercised.add(match.groups())

    print(f"Observed GPU frames: {frame}")
    print(f"Render function pairs bound in trace: {len(exercised)}")
    print(f"Rejected render states: {sum(rejected.values())} events, {len(rejected)} distinct")
    for (vertex, vertex_id, fragment, fragment_id, error), count in rejected.most_common():
        print(f"  {count}x {vertex} [{vertex_id}] / {fragment} [{fragment_id}]: {error}")
        if args.libraries:
            for stage, identity in (("vertex", vertex_id), ("fragment", fragment_id)):
                digest, _, origin = identity.partition(":")
                if len(digest) == 64 and origin != "ios-air":
                    path = args.libraries / f"sonoma-ioslib-{digest}.metallib"
                    print(f"    {stage} iOS conversion: {'available' if path.exists() else 'missing'} ({digest})")
    print(f"Rejected compute states: {sum(compute_rejected.values())} events, {len(compute_rejected)} distinct")
    print("Compute coverage (function and library hash): " + ", ".join(
        f"{stage}={len(pairs)}" for stage, pairs in compute_coverage.items()))
    for (function, identity, error), count in compute_rejected.most_common():
        print(f"  {count}x {function} [{identity}]: {error}")
    if compute_retried:
        print("Compute pipelines created after AIR retry (execution not established): " + ", ".join(sorted(compute_retried)))
    print(f"Unsupported surface descriptors: {sum(surfaces.values())} events")
    for reason, count in surfaces.most_common(12):
        print(f"  {count}x {reason}")
    print(f"Private mapped-texture fallback events: {sum(fallbacks.values())} (require visual review)")
    if not fallback_diagnostics:
        print("  Coverage uncertain: this log lacks unconditional fallback diagnostics; zero is not a clean mapping pass.")
    for (size, pixel_format), count in fallbacks.most_common(12):
        print(f"  {count}x {size}, format {pixel_format}")
    reported_errors: Counter[str] = Counter()
    for (_, _, _, _, error), count in rejected.items():
        reported_errors[error] += count
    for (_, _, error), count in compute_rejected.items():
        reported_errors[error] += count
    for detail in pipeline_diagnostics:
        if reported_errors[detail]:
            reported_errors[detail] -= 1  # its structured rejected-state line already reports it
            continue
        other["other pipeline/library errors"] += 1
    for reason, count in other.most_common():
        print(f"{reason}: {count}")
    if args.previous_log:
        prior = set()
        prior_compute = set()
        for line in args.previous_log.read_text(errors="replace").splitlines():
            if match := REJECTED.search(line):
                prior.add((match[1], match[3]))
            if match := COMPUTE_REJECTED.search(line):
                prior_compute.add((match[1], match[2].split(":", 1)[0]))
        failing = {(vertex, fragment) for vertex, _, fragment, _, _ in rejected}
        print("Previous rejected function pairs (name coverage, not pixel correctness):")
        for pair in sorted(prior):
            status = ("still rejected" if pair in failing else
                      "bound without logged rejection" if pair in exercised else
                      "UNOBSERVED: not verified by this run")
            print(f"  {pair[0]} / {pair[1]}: {status}")
        if prior_compute:
            print(f"Previously rejected compute identities: {len(prior_compute)}")
            for stage, pairs in compute_coverage.items():
                print(f"  {stage}: {len(prior_compute & pairs)}/{len(prior_compute)}")
            for function, digest in sorted(prior_compute - compute_coverage["queried"]):
                print(f"  query UNVERIFIED: {function} [{digest}]")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
