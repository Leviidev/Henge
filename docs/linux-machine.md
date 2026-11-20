# The Linux machine

HengeVM's engine runs arm64 code with its own JIT, MMU and devices, so it is not
tied to macOS. `devices/linuxvirt.c` puts a generic arm64 machine for Linux
guests on the same engine and devices as the virtual Mac: a real Linux kernel,
so systemd, snaps, containers and kernel modules behave as on any arm64 computer.

## The machine

Same addresses as the virtual Mac (`devices/vmapple.h`), booted the way Linux
boots on any arm64 board: the kernel `Image` is loaded directly at the start of
RAM, a device tree describing the machine is generated (`devices/fdt.c`) and
handed over in x0, and there is no boot ROM.

| Device | Address | Linux driver |
| --- | --- | --- |
| GICv3 distributor / redistributors | 0x10000000 / 0x10010000 | `arm,gic-v3` |
| Generic timer (virtual timer, PPI 27) | — | `arm,armv8-timer` |
| PL011 UART (SPI 1) | 0x20010000 | `arm,pl011` (`ttyAMA0`) |
| PL031 RTC (SPI 2) | 0x20050000 | `arm,pl031` |
| PSCI 1.0 over HVC | — | `arm,psci-1.0` (CPU_ON, power off, reset) |
| PCIe ECAM / 32-bit window | 0x40000000 / 0x50000000 | `pci-host-ecam-generic`, INTx: slot s is SPI 0x20 + s |
| virtio-pci block, network, input | PCIe | `virtio_blk`, `virtio_net`, `virtio_input` |
| virtio-gpu (the display; 3D with virgl) | PCIe | `virtio_gpu` (DRM/KMS; Mesa's virgl driver in the guest) |
| simple-framebuffer (instead, with `HV_LINUX_FB`) | top of RAM | `simpledrm` / `simplefb` |
| RAM | 0x70000000 | — |

The CPU starts at EL1 (HengeVM plays EL2), as on a VM host without nested
virtualization: Linux reports "CPU: All CPU(s) started at EL1" and has no KVM.

## Trying it without a phone

`tools/hengelinux` boots a kernel from the command line with the serial console
on the terminal (Ctrl-A x quits). `make linux-test` builds it for an arm64 Linux
host; `host/linux/` stands in for the few Mach and Apple headers the engine
includes. On an x86 machine it runs under `qemu-aarch64` (a JIT inside a JIT, so
very slow; `HV_CLOCK_DIV=20` slows the guest's clock so a 250 Hz kernel is not
all timer ticks):

```sh
make linux-test
qemu-aarch64 -cpu max build/linux/hengelinux --kernel Image --initrd initrd.gz \
    --append "console=ttyAMA0 rdinit=/init"
HV_CLOCK_DIV=20 qemu-aarch64 -cpu max build/linux/hengelinux --kernel Image \
    --disk ubuntu.img --cpus 2 --ram 2048 --append "console=ttyAMA0 root=/dev/vda rw"
```

`--kernel` takes an uncompressed arm64 `Image` (Ubuntu's `vmlinuz` is gzip:
`zcat vmlinuz > Image`). Without an initramfs, use `root=/dev/vda`, not a label.

## Tested so far (qemu-aarch64 on x86, 2026-11-18)

Kernel: Ubuntu 24.04's stock `linux-image-unsigned-6.8.0-149-generic` (arm64).

- Boots to a BusyBox shell from an initramfs; finds the PCIe host bridge and the
  virtio devices; powers off through PSCI.
- Two CPUs (PSCI CPU_ON, the second redistributor), and an ext4 root file system
  on virtio-blk.
- The simple-framebuffer: Linux's `simpledrm` driver takes it and the text
  console draws on it (`HV_FB_DUMP=file.ppm` saves it when the tool stops).
- One engine fix was needed: the translator read macOS's commpage to inline
  counter reads, which a Linux host does not have (`core/translate.c`).

Not tried yet: a phone, input, network, sound, the desktop.

## The kernel: 16 KB pages

HengeVM's software TLB keeps 16 KB pages, macOS's and the iPhone's size; a guest
mapping smaller pages takes the slow path, a table walk, on every access
(`core/mmu.c`, `tlb_fill`). Ubuntu's stock arm64 kernel uses 4 KB pages, so its
user space crawled: on the arm64 CI runner one boot service (AppArmor compiling
snap profiles) took 18 minutes. `tools/linux/build-kernel.sh` builds Linux (6.12
long-term) from arm64 defconfig plus `tools/linux/henge-kernel.config`: 16 KB
pages, a 47-bit VA (three table levels, as macOS), the machine's devices built in,
and what Ubuntu needs. The same BusyBox work on the engine (qemu-aarch64 host,
guest seconds):

| | Ubuntu 6.8, 4 KB pages | Henge 6.12, 16 KB pages |
| --- | --- | --- |
| shell loop (3000 iterations) | 1.97 s | 0.02 s |
| gzip of 16 MB | 25.6 s | 0.14 s |
| md5 + sha256 of 4 MB | 9.3 s | 0.05 s |

With it, Ubuntu 24.04 boots to its signed-in console with systemd and snapd in
under a minute on the arm64 runner (4 CPUs, 4 GB).

User space is Ubuntu's own. Programs that assume 4 KB pages (a few allocators and
JITs built that way) may not run on a 16 KB kernel, as on Asahi Linux.

## An Ubuntu machine

`tools/linux/make-ubuntu-disk.sh` makes a folder the app brings in, from Ubuntu
as it is: the arm64 cloud root file system and the stock generic kernel (the
release's own series, 6.8 for 24.04), the kernel uncompressed (`Image`) and its
modules indexed with `depmod` (they are not installed as packages, so nothing
else would). A `henge` user with no password signs in on the consoles and has
sudo; the network is DHCP on virtio-net. `--desktop` adds Xfce with LightDM
signing in by itself, restyled after Ubuntu (Yaru, the Ubuntu font, a dock);
`--gnome` adds Ubuntu's own desktop, GNOME Shell with Ubuntu's session, dock and
theme, GDM signing in by itself, without the first-run setup, the welcome tour,
the screen lock or animations (Settings > Accessibility turns those back on).
Both get Firefox as Mozilla's deb (Ubuntu's firefox package is the snap). apt
runs inside the image, so these need an arm64 host.

```sh
sudo tools/linux/make-ubuntu-disk.sh ~/Ubuntu --size 24G --desktop --pack
```

The folder holds `Image`, `disk.img.hvsparse` (the disk with its holes left out)
and `machine.json` with `"kind": "linux"` and the kernel's command line.

`.github/workflows/linux-machine.yml` does the same on a GitHub-hosted arm64
runner, where the engine runs natively: it builds `tools/hengelinux`, makes the
Xfce and the GNOME machine (a job each), boots each with `henge.autotest` on the
command line (`/usr/local/bin/henge-autotest` in the image then reports what came
up on the serial console, asks for a screenshot and powers off), again with virgl
3D both ways, and uploads each folder as an artifact if its desktop came up. The
app's build attaches them to its release as `Henge-Ubuntu-Xfce.zip` and
`Henge-Ubuntu-GNOME.zip`.

## In the app

Bring the folder in like an exported Mac: drop it on Henge in Finder, or pick it
in the Files app. A `"kind": "linux"` machine.json makes it a Linux machine: its
`Image` (and `initrd.img`, if there is one) instead of the boot ROM and
auxiliary storage, a 1280 x 800 screen, and `henge_vm_boot_linux` to start it.
Instant resume is off for it (the snapshot format holds the Mac's devices).

What runs on the phone, and how:

- **Machine:** `hv_vm_create` builds `linuxvirt` when `HvVmConfig.linux_kernel`
  is set; its devices are in the virtual Mac's board, so the input, disk,
  network and sound code is the Mac's. Guest RAM comes from
  `hv_vmapple_alloc_ram`, outside the app's footprint where iOS allows it.
- **Display:** virtio-gpu (see "The GPU" below), its screen handed to
  `BootDisplay.swift` through `hv_vm_boot_display` (32-bit BGRA, a copy with
  the pointer drawn in). `HV_LINUX_FB` in the environment brings back the
  simple-framebuffer instead.
- **Input:** for now the virtio keyboard and mouse (`host/vm.c`, "Input for the
  Linux machine"): keys from the app's on-screen and hardware keyboards go to the
  virtio keyboard; on the iPhone trackpad one finger moves the pointer, two
  scroll, a tap clicks and a two-finger tap right-clicks.
- **USB (off):** the Mac's xHCI controller with its USB keyboard and Magic
  Trackpad 2 would give Linux the trackpad itself (`hid-magicmouse`, libinput's
  gestures). Linux finds its ports once the Supported Protocol capability gives a
  port count rather than a mask (`hv_xhci_spec_ports`), but then a transfer event
  pointing at an earlier TD than the one its driver waits for leads it to a
  stale command and a panic (`hengelinux --usb` shows it). macOS's driver
  tolerates the same events.
- **Network and sound:** virtio-net on the user-mode network, virtio-snd.

## The GPU

`devices/virtio_gpu.c` is a virtio-gpu device, which Linux's `virtio_gpu` DRM
driver drives: the guest has a real KMS display (modes up to 4K, page flips, a
hardware pointer) and Xorg uses its `modesetting` driver.

- **2D:** the guest's resources are kept in host memory, filled from its pages
  by TRANSFER_TO_HOST_2D; RESOURCE_FLUSH on the scanned-out one copies the
  damaged rectangle to the screen.
- **3D (virgl):** with a renderer (`HvVgpu3d`, filled by `devices/vgpu_virgl.c`)
  the device offers `VIRTIO_GPU_F_VIRGL` and the two virgl capsets, and passes
  contexts, 3D resources, transfers, command buffers and fences to
  virglrenderer, which runs the guest's Gallium commands on the host's OpenGL
  or OpenGL ES. virglrenderer and its GL contexts live on a thread of their own;
  scanned-out 3D resources are read back for the screen.
  - On a Linux host (`make linux-test LX_VIRGL=1`, `hengelinux --virgl`) it uses
    the host's Mesa through surfaceless EGL. On GitHub's arm64 runner Xorg in the
    guest reports *glamor X acceleration enabled on virgl*.
  - On iOS there is no Mesa: the renderer is virglrenderer on ANGLE, which draws
    with Metal (as UTM does). `ios/scripts/build-gpu-deps.sh` builds ANGLE,
    libepoxy and virglrenderer from UTM's forks as frameworks (the *iOS GPU
    libraries* workflow, cached for the app's build); the app embeds them and
    the engine loads them when a Linux machine starts (`HV_VIRGL_DLOPEN`),
    making the EGL display on ANGLE's Metal backend and handing virglrenderer
    its contexts (`HV_VIRGL_ANGLE`). Without them the GPU is 2D.
    `HV_VIRGL_OWN_EGL=1 hengelinux --virgl` takes that path on Linux, with
    Mesa's EGL, and the CI boots it too.

Next for the GPU: the screen as a Metal texture (UTM's virglrenderer can hand
out a resource's `MTLTexture`) rather than read back, a CAMetalLayer for it, and
the display following the app's window size.

## Next

- Try it on a phone.
- Saving a Linux machine (instant resume).
