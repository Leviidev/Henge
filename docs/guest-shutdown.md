# Guest shutdown and restart

PSCI `SYSTEM_OFF` and `SYSTEM_RESET` stop the whole machine. `CPU_OFF` only
parks one CPU until a later `CPU_ON`. A parked CPU waits on `wake_cv`, so setting
`halted`, an exit request, and an ARM event alone cannot release it. In
particular, CPU 0 may be parked when a secondary requests shutdown.

`hv_machine_halt` publishes a terminal reason and wakes every CPU, including
those parked in `CPU_OFF`. The halt reason is atomic. The per-CPU wake lock
serializes it with `CPU_ON` so a concurrent reset cannot clear shutdown.
`CPU_ON` also abandons its wait when the machine stops. A later host cleanup
request preserves the guest's original terminal reason.

For the asynchronous app runner, CPU 0 joins the secondary CPU threads and
stops the periodic kicker, finishes submitted block requests and stops audio
before flushing disks and calling the exit callback. Guest shutdown, restart,
host stop, panic and execution failures remain distinguishable; a generic
dispatcher `HALT` is not sufficient to identify a normal shutdown.

The native bridge stays in a transitional state until network workers, GPU
work and device callbacks have drained, the disks have closed, and the old
board, guest RAM and translation metadata have been released. UI readers are
excluded during teardown, and boot display snapshots own their pixel copies.
The bridge then publishes the stopped state and permits another boot. The
app's borrowed JIT mapping survives teardown, so the next boot reuses it
without repeating the debugger handoff. Failed normal boots also release
their partial machine and allow retry.

The session view removes guest input controls, releases captured input, restores
normal device sleep and shows a terminal message. `BootDisplay` keeps watching
the VM state after GPU rendering begins, then removes the last rendered frame
on both the device and an external display. The stopped card offers **Start
Mac** and **Close**. A guest restart request automatically starts the next boot;
closing the session and opening a Mac again also works in the same app process.
Each successful boot increments a generation counter so the display discards
the previous boot's frame and watches for the new GPU output.

This applies to normal boots of installed guests. The installer has separate
long-lived USB restore workers and retains its existing reopen-the-app
restriction; this change does not release a board still owned by those workers.

## Regression checks

On an Apple Silicon Mac:

```sh
make build/test_shutdown build/test_exc build/test_devices
ulimit -s 65520
build/test_shutdown
build/test_exc
build/test_devices
```

`test_shutdown` executes guest HVC instructions with other CPUs already parked,
including CPU 0. It covers shutdown and reset from CPU 0 and a secondary, no
further guest instructions after a power request, preservation of the terminal
reason during host cleanup, and cancellation of pending CPU_ON calls. Waits
are bounded, with cleanup to release threads even when the regression fails.

`make test-vm-lifecycle` additionally needs the app's libslirp development
dependencies. It links the production native bridge and engine, supplies a
test JIT mapping, and uses a tiny synthetic ROM. It covers 12 alternating guest
shutdown, guest reset and host stop cycles, three failed boots, concurrent UI
reads, retained JIT memory, and returned file/thread counts. It needs no Apple
ROM or guest disk. The test was run with the iOS Simulator dependency build.

`make build/test_pvg_lifecycle` builds a Metal lifecycle test for Apple Silicon.
Run `build/test_pvg_lifecycle` to queue 384 command completions over six renderer
creations and destructions, checking that teardown drains the callbacks before
freeing the board. These empty commands do not test guest image rendering.

## Validation on 2026-11-08

Base: upstream `ba9392e7ce13c6e80f2a635cf4a10336f27c0964`.

- Before the fix, the four parked-CPU power-request cases produced eight
  failures: parked threads remained asleep. After the fix, all shutdown tests
  passed on macOS and iOS Simulator.
- Exception tests: 52 checks passed on macOS and iOS Simulator. Device tests:
  97 checks passed on macOS. JIT tests (10 programs, two seeds), memory tests
  (12 cases in three modes plus MMIO) and MMU tests (72 checks) also passed.
  The complete Swift app and both renderer targets compiled, and the existing
  display checks passed.
- The native lifecycle test completed all 12 power cycles and three failed
  boots with zero failures in iOS Simulator, including concurrent UI readers.
  The Metal lifecycle test completed all six cycles on the Mac's M3 Max GPU.
- A separate iOS Simulator harness linked the production engine, native
  bridge, `BootDisplay` and `StoppedMacView`. A real macOS 15.6.1 (24G90) guest
  with four software CPUs and 6 GB RAM completed three boots in one app
  process: shutdown, restart request, then shutdown. All used the same JIT
  address; each stopped with zero active guest CPUs and 11 file descriptors.
- A second harness used the production **SessionView** and its normal boot
  preparation. An XCTest UI test completed four real guest boots in process
  16315 with the same JIT address, 4507533312: guest shutdown, tap **Start
  Mac**, guest-requested restart with automatic next boot, another shutdown,
  then **Close** and **Open Mac** followed by a final shutdown. The UI test
  passed with zero failures. Its saved screenshot shows "Mac shut down",
  **Start Mac** and **Close**, with the old guest frame removed. At the final
  stopped state, active guest CPUs were zero and file descriptors were 11.
- Test adapters replace the physical device's debugger handoff and use a
  shorter Unix socket path for file sharing inside the simulator. The latter
  avoids the simulator container path exceeding the socket address limit;
  production file-sharing paths were not changed.
- Simulator guest Metal rendering was disabled because its buffer-backed
  texture implementation rejected the production renderer's storage mode.
  The device package retains normal graphics. These tests validate real guest
  power requests and the production session's repeated-boot UI, while the
  separate Metal test exercises completion cleanup.
- The user subsequently verified normal guest shutdown and restart on iPhone
  Duo running with iOS 27.3 Beta 1.
