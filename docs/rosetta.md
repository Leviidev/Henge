# Intel apps (Rosetta 2)

macOS runs x86_64 apps through Apple's Rosetta 2. Before it accepts an x86_64
binary, the kernel checks that the CPU has Apple's x86 extensions, and
Rosetta's translated code relies on them. Henge emulates the ones macOS
Sequoia checks for:

| What | How the guest sees it | What Henge does |
|---|---|---|
| Total store ordering (TSO) | AIDR_EL1 bit 9; the kernel sets ACTLR_EL1 bit 1 (EnTSO) for translated threads | Their EL0 code is translated with barriers around every memory access (`HV_BLOCK_TSO`) |
| x86 parity and adjust flags | AIDR_EL1 bit 19; ACTLR_EL1 bit 4 (EnAPFLG); NZCV bits 26 and 27; APSTATE (`S3_6_C15_C8_3`) | Flag-setting arithmetic computes PF and AF too (`HV_BLOCK_APF`) |
| Alternate floating-point behaviour | ID_AA64MMFR1_EL1.AFP | Offered when the host CPU has FEAT_AFP; FPCR keeps FIZ, AH and NEP |
| CFINV, XAFLAG, AXFLAG | ID_AA64ISAR0_EL1 says FlagM2 | Run as they are |

The extensions are always on: native arm64 code never sets EnTSO or EnAPFLG,
so it is translated as before.

## Which devices

macOS 15.6.1 (24G90) accepts x86_64 binaries only when the CPU reports
ID_AA64MMFR1_EL1.AFP (or Apple's own float-mode bits, which Henge does not
emulate). Henge passes FEAT_AFP through rather than emulating it, so Intel
apps need a host chip with FEAT_AFP: `sysctl hw.optional.arm.FEAT_AFP`
prints 1 on such a Mac, and Henge reads the same value on iOS. Elsewhere
x86_64 binaries still fail with "Bad CPU type in executable".

Tested so far only on M4-family hosts (an M4 Max Mac, an iPad Pro with M4)
and an iPhone Duo, all with macOS 15.6.1 as the guest. Other guest versions
may check other bits.

## Installing Rosetta in the guest

`softwareupdate --install-rosetta` says Rosetta is not available on this
virtual Mac. Apple's package for the guest's exact build installs fine:

1. In the guest, note the build: `sw_vers -buildVersion` (24G90 for 15.6.1).
2. Download Apple's catalog,
   `https://swscan.apple.com/content/catalogs/others/index-rosettaupdateauto-1.sucatalog.gz`,
   and find the product whose `ExtendedMetaInfo` has that `BuildVersion`.
   Its package is `RosettaUpdateAuto.pkg` on swcdn.apple.com.
3. Copy it into the guest, check it with `pkgutil --check-signature`, and
   install it: `sudo installer -pkg RosettaUpdateAuto.pkg -target /`.
4. `arch -x86_64 /usr/bin/uname -m` prints `x86_64`.

## Checking it

`tools/x86_rosetta_check.c` runs 50 x86 instructions on 24×24 inputs, both
from Rosetta's ahead-of-time translation and from its JIT, and prints a hash
of the flags each one leaves, plus float compares with NaN and a TSO
message-passing test. Build it on an Apple silicon Mac:

```sh
clang -arch x86_64 -O1 -o x86_rosetta_check tools/x86_rosetta_check.c
```

Run it on the Mac and in the guest and compare the output: every line but
the TSO one must match, and the TSO line must report 0 violations.
