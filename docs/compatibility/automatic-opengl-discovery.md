# Automatic OpenGL discovery investigation

Automatic normal-app activation remains incomplete. The process-local helper
supplies a missing `IOGLBundleName` only when queried on AppleParavirt objects;
its successful renderer controls do not establish a global installation route.

## Artifact identity and method

This investigation used the retained Sonoma 14.6.1 / 23G93 restore image.
Its BuildManifest version/build were checked, and the ZIP member
`kernelcache.release.vma2` matched the retained IM4P exactly:
`66ef41611bd978d8b9e28cce35f83e2e638e06a6c24055cb1042e724faf2e3ba`.
Independent IM4P extraction reproduced kernelcache SHA-256
`80894ff3eeda33b9be2b6a275098a013cbca7e3ca61c4f2ea4038eeb80809783`.
The fileset entry's UUID matched the extracted AppleParavirtGPUIOGPUFamily
UUID `21fdd0f5-f3ca-35fe-9468-1acd5450f813`; that extracted artifact hashes to
`49d326bbfc9013d5d11318df640db07c69a543b97c30ef7ae2d9015bb8b40e85`.
The kernel identifies itself as Darwin 23.6.0, xnu-10063.141.2~1,
RELEASE_ARM64_VMAPPLE.

Observations below come from Xcode `nm`/`llvm-objdump`, bounded Mach-O/UUID
inspection and the existing host source. REA's old Hopper process was absent,
cleanup acknowledgement was unavailable, and its independent CLI confirmed no
installed Hopper launcher; Ghidra/IDA were not configured. No decompiler or live
execution evidence is claimed. Captured binaries and Apple disassembly stay out
of the source tree.

## Two bounded negative findings

1. **A userland registry setter is not a supported route on this driver.**
   AppleParavirtGPU's vtable at `0xfffffe00078bbbd8` has the inherited
   IORegistryEntry `setProperties(OSObject*)` at vptr offset `0x320`.
   The authenticated cache-offset mapping was independently anchored by both
   destructor entries. The setter resolves to `0xfffffe00083329ec`; its entire
   function returns `0xe00002c7`, the SDK's `kIOReturnUnsupported`.
   This is static dispatch evidence, not an observed setter invocation.
2. **GetDeviceInfo is not a general registry-property dictionary channel.**
   `AppleParavirtGPU::setupDeviceInfo()` receives numeric device information and
   calls `parseDeviceInfo` at `0xfffffe0008a6d970`. Through its final return at
   `0xfffffe0008a6dc7c`, that parser walks eight-byte key/value records, handles
   keys up to `0x20`, and stores numeric fields/presence flags. It has no call
   instructions or string/dictionary installation path. The host's corresponding
   table is `device_info` in `devices/pvg_lite.c`. Adding an invented integer key
   is therefore not an implementation of the missing renderer-name property.
   This does not exclude an existing capability affecting later startup policy.

The retained stock device tree was also parsed completely: 123 nodes, all
54,664 bytes consumed, SHA-256
`84fa618ee228a82edff0d1fd744190e0192ef2faf366c87813249bd2db9ddd38`.
`/device-tree/arm-io/gfx` identifies `paravirtualizedgraphics,gpu` and has no
`IOGLBundleName`. Inventory alone does not establish whether adding a provider
property would propagate to the accelerator object queried by OpenGL.

## Required next evidence

Trace generic IOGPU startup/personality handling and provider-to-accelerator
property propagation before attempting a device-tree change. A global route
must be tested by opening ordinary apps without the discovery launcher and
checking accelerated renderer selection and pixel readback. Preserve application
signing and existing security policy. Guest login-wide injection, personality
merging and boot-time device-tree changes are hypotheses, not implemented fixes.

No guest/kernel/firmware bytes, registry properties, app environments or live
machine files were changed by this investigation. The on-device provisioning,
activation, fresh-guest and final-binary gates in [distribution acceptance](distribution-plan.md) remain open.
