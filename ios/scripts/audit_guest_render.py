#!/usr/bin/env python3
"""Compare two Henge captures of the same guest scene.

Capture the scene once with a known-good shader set, then again after changing
one shader. This catches pipelines that compile but draw the wrong pixels.
Dynamic parts of the scene (clock, cursor, progress indicators) can be masked.
Optional logs report newly rejected Metal pipelines in the candidate run.

For a small defect, use --region x,y,width,height around it. For a full-screen
scene, mask the clock and other expected animation. Keep the same resolution,
guest state, and scene in both captures.
"""

import argparse
from pathlib import Path
import re

from PIL import Image, ImageChops


PIPELINE_ERROR = re.compile(r"pvg-metal: (?:pipeline \d+ \([^)]*\)|compute pipeline \([^)]*\)|library): (.+)")
SURFACE_ERROR = re.compile(r"pvg-metal: surface \d+: unsupported Sonoma descriptor")


def failures(path: Path) -> set[str]:
    return {
        line.split("pvg-metal: ", 1)[1].strip()
        for line in path.read_text(errors="replace").splitlines()
        if PIPELINE_ERROR.search(line)
    }


def rectangle(value: str) -> tuple[int, int, int, int]:
    parts = tuple(map(int, value.split(",")))
    if len(parts) != 4 or min(parts) < 0 or parts[2] == 0 or parts[3] == 0:
        raise argparse.ArgumentTypeError("mask must be x,y,width,height with positive size")
    return parts


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("reference", type=Path)
    parser.add_argument("candidate", type=Path)
    parser.add_argument("--region", type=rectangle,
                        help="compare only x,y,width,height (default: full image)")
    parser.add_argument("--mask", type=rectangle, action="append", default=[])
    parser.add_argument("--blank-region", type=rectangle, action="append", default=[],
                        help="region expected to contain artwork/text, not a solid white placeholder")
    parser.add_argument("--max-white", type=float, default=0.20,
                        help="maximum near-white fraction in each blank-region check")
    parser.add_argument("--detail-region", type=rectangle, action="append", default=[],
                        help="region expected to contain textured artwork rather than a flat fill")
    parser.add_argument("--min-entropy", type=float, default=2.5,
                        help="minimum grayscale entropy in each detail-region check")
    parser.add_argument("--pixel-tolerance", type=int, default=35)
    parser.add_argument("--max-different", type=float, default=0.10,
                        help="maximum fraction of unmasked pixels that may differ")
    parser.add_argument("--reference-log", type=Path)
    parser.add_argument("--candidate-log", type=Path)
    parser.add_argument("--diff", type=Path, help="write a contrast-enhanced difference image")
    args = parser.parse_args()

    reference = Image.open(args.reference).convert("RGB")
    candidate = Image.open(args.candidate).convert("RGB")
    if reference.size != candidate.size:
        parser.error(f"image sizes differ: {reference.size} and {candidate.size}")
    width, height = reference.size
    left, top, region_width, region_height = args.region or (0, 0, width, height)
    if left + region_width > width or top + region_height > height:
        parser.error("region extends beyond the image")
    if not 0 <= args.max_white <= 1:
        parser.error("--max-white must be between 0 and 1")
    if args.min_entropy < 0:
        parser.error("--min-entropy must be nonnegative")
    difference = ImageChops.difference(reference, candidate)
    pixels = difference.load()
    changed = included = 0
    for y in range(height):
        for x in range(width):
            if not (left <= x < left + region_width and top <= y < top + region_height):
                pixels[x, y] = (0, 0, 0)
                continue
            if any(left <= x < left + w and top <= y < top + h
                   for left, top, w, h in args.mask):
                pixels[x, y] = (0, 0, 0)
                continue
            included += 1
            if max(pixels[x, y]) > args.pixel_tolerance:
                changed += 1
    fraction = changed / included if included else 0
    print(f"Changed pixels: {changed}/{included} ({fraction:.1%}); limit {args.max_different:.1%}")
    blank_failure = False
    for x, y, w, h in args.blank_region:
        if x + w > width or y + h > height:
            parser.error(f"blank region {(x, y, w, h)} extends beyond the image")
        white = sum(
            min(rgb := candidate.getpixel((px, py))) >= 245 and max(rgb) - min(rgb) <= 8
            for py in range(y, y + h) for px in range(x, x + w)
        )
        white_fraction = white / (w * h)
        print(f"Blank region {(x, y, w, h)}: near-white {white_fraction:.1%}; limit {args.max_white:.1%}")
        blank_failure |= white_fraction > args.max_white
    for x, y, w, h in args.detail_region:
        if x + w > width or y + h > height:
            parser.error(f"detail region {(x, y, w, h)} extends beyond the image")
        entropy = candidate.crop((x, y, x + w, y + h)).convert("L").entropy()
        print(f"Detail region {(x, y, w, h)}: entropy {entropy:.2f}; minimum {args.min_entropy:.2f}")
        blank_failure |= entropy < args.min_entropy
    if args.diff:
        difference.point(lambda value: min(255, value * 4)).save(args.diff)
        print(f"Difference image: {args.diff}")

    new_failures: set[str] = set()
    if args.reference_log and args.candidate_log:
        new_failures = failures(args.candidate_log) - failures(args.reference_log)
        print(f"New rejected pipelines/libraries: {len(new_failures)}")
        for item in sorted(new_failures):
            print(f"  {item}")
        for label, path in (("Reference", args.reference_log), ("Candidate", args.candidate_log)):
            count = sum(bool(SURFACE_ERROR.search(line))
                        for line in path.read_text(errors="replace").splitlines())
            print(f"{label} unsupported surface mappings: {count}")
    elif args.reference_log or args.candidate_log:
        parser.error("provide both log paths to compare pipeline failures")
    return int(fraction > args.max_different or blank_failure or bool(new_failures))


if __name__ == "__main__":
    raise SystemExit(main())
