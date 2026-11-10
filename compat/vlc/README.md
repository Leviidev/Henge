# Optional VLC3.0.24 export source fixes

These patches repair ordinary H.264/HEVC + AAC export on the tested arm64 Sonoma route. They are separate from Henge's GPU renderer changes. This directory distributes source and patch provenance, not a VLC app, signed plugins, Apple frameworks, encoded fixtures or captured audio.

The six VLC patches cover AAC priming/end padding through demux/packetizer/decoder, delayed encoder samples and planar final flush, cumulative resampling duration, final transcode/mux drain and MP4 edit timing, x265 timestamps and VUI forwarding, and the native macOS HEVC codec menu. A libsamplerate patch drains constant-rate EOF correctly, including the final 44.1 kHz rounding sample. x265's small CMake patch allows the pinned static build. `source-provenance.json` records exact before/after source hashes; `inputs.lock.json` pins archives. Do not cherry-pick only a gapless metadata consumer: all nine plugins form one compatibility unit and share the versioned metadata extension. Build-time ABI checks preserve the official core's structure sizes and pointer offsets.

On an Apple Silicon Mac, supply the official thin arm64 VLC3.0.24 app read-only, Xcode/command-line tools, Python3, CMake and make. `build.py` fetches only the locked public source archives when `--fetch` is supplied. It builds FFmpeg8.1.2 (minimal static AAC/MOV), x2654.1 build215 (assembly disabled), libsamplerate0.1.9 and the nine plugins for macOS14.0+. All intermediate sources, exact commands and logs remain under the output directory. The reference app's libvlccore and Sparkle are linked read-only, never redistributed by this source package.

```sh
python3 compat/vlc/build.py --vlc-app /path/Official/VLC.app \
  --archives .compat-local/vlc-archives --output .compat-local/vlc-build --fetch
python3 compat/vlc/candidate.py --source-app /path/Target/VLC.app \
  --build .compat-local/vlc-build --output .compat-local/vlc-candidate
python3 compat/vlc/generate_fixtures.py --output .compat-local/vlc-fixtures
python3 compat/vlc/test_exports.py --candidate .compat-local/vlc-candidate \
  --fixtures .compat-local/vlc-fixtures --output .compat-local/vlc-regression
```

The target app must use the exact reference libvlccore. Candidate creation copies it, retains its Info.plist (including LSEnvironment), main executable content and load commands, installs the nine built plugins into that copy, and signs the copy while preserving entitlements. Existing target-specific CGL compatibility therefore remains intact. No arbitrary app security bypass is introduced. Use an output directory outside cloud/File Provider managed folders: those services can add Finder metadata that invalidates strict signature checks after a move. Final candidate verification rejects that condition. The target's full file/symlink tree is recorded for guarded later promotion. FFmpeg/FFprobe with testsrc2, libx264 and AAC are separate host verification tools; use `--ffmpeg`/`--ffprobe` to select them and retain the recorded version/fixture manifest. These are not guest runtime dependencies.

The resampler's focused source regression is also reproducible independently:

```sh
python3 compat/vlc/test_samplerate.py --build .compat-local/vlc-build \
  --archives .compat-local/vlc-archives --output .compat-local/samplerate-tests
```

It freshly builds the original pinned libsamplerate and compares it with the
patched build across 18 authored EOF cases (1/2/4/6 channels, down/up/same-rate,
short and non-integral durations, streaming and final-block input). It checks
exact output frame counts and byte-identical common PCM, preserving the missing
sample failure control without redistributing a recorded fixture.

The regression generates authored media and checks six default-module cases: BT.601 x264/x265, BT.709 x265, full-range non-square-SAR x264/x265, and non-integral-duration stereo audio. It verifies actual decoded frames/samples, strict packet DTS/decoded PTS, color/SAR, audio SNR, RGB PSNR/SSIM, A/V start timing, decoder warnings and selected modules. There are no explicit encoder or hardware-decoder CLI overrides. Minimal normal preferences are `codec=avcodec` and `avcodec-hurry-up=0`; no `avcodec-hw=none` is needed in this route.

Clean source-built native regression passed all six authored cases. The original versioned source changes also passed actual guest native Convert/Stream and normal installed-app entry for H.264 and HEVC, with 300 decoded frames and exactly441000 audio samples over10s. New builds and another iPad still need their own guest six-case run, actual GUI Convert/Stream checks, visible playback and physical audio acceptance. A native headless pass does not replace those gates. Long media, arbitrary source codecs, HDR and all GUI profiles are not qualified by these bounded tests.

## Promote only after the candidate passes the target GUI gate

Copy the candidate, `promote.pl`, `macho-content.pl`, source tree hashes and validation receipts to the guest using your authenticated transport. Guest promotion uses stock `/usr/bin/perl`, JSON::PP, Digest::SHA and standard macOS tools; it does not require Python or Xcode CLT. Check availability with `/usr/bin/perl -MJSON::PP -MDigest::SHA -e 1`. The Python equivalent is for a host with Python and also needs `tools/compat/ipad_update.py` for shared Mach-O identity. Close VLC. Test the candidate through LaunchServices with only its isolated config, so its existing LSEnvironment applies:

```sh
open -n '/path/candidate/VLC Export Test.app' --args --config /path/candidate/vlc-export.ini
```

Use Convert/Stream with native H.264 and HEVC selections, AAC and MP4/MOV, then independently decode the completed outputs and save a receipt. The promotion tool takes that explicit operator-validated receipt, binds its SHA and enforces candidate/source app hashes; it does not infer GUI success from the receipt's mere existence. On the guest, use the real installed app and current user's normal VLC config path:

```sh
/usr/bin/perl /path/promote.pl install --candidate /path/candidate \
  --app /Applications/VLC.app --config "$HOME/Library/Preferences/org.videolan.vlc/vlcrc" \
  --backup "$HOME/Library/Application Support/Henge Compatibility/VLC-before-fixes" \
  --validated-gui-receipt /path/gui-validation.json
```

All Perl-tool paths must be absolute. Backup must be new and on the app's filesystem. The tool refuses a running app or changed source tree, retains the complete original app by rename, preserves original preferences privately, and merges only the two decoder preferences above. It never changes CGL environment/load commands or installs a second permanent app. After promotion, double-click normal `/Applications/VLC.app` with no wrapper/config flags and repeat export, playback and audio acceptance. Save that separate installed-entry receipt.

Rollback retains both versions and restores the complete original preferences only if neither installed files nor config changed since promotion:

```sh
/usr/bin/perl /path/promote.pl restore \
  --backup "$HOME/Library/Application Support/Henge Compatibility/VLC-before-fixes" \
  --retain-current "$HOME/Library/Application Support/Henge Compatibility/VLC-export-candidate.app"
```

If normal preferences changed afterward, the tool stops for a deliberate merge rather than discard them. Packaging/control-script tests do not constitute authorization to replace an unrelated installed app. Keep private backups, logs and generated binaries outside version control. VLC and dependency copyright/licensing remain with their original authors; included COPYING/COPYING.LIB and patch headers retain notices. Distributors of binaries must also satisfy each corresponding-source obligation.
