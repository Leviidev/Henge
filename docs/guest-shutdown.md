# Guest shutdown

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
stops the periodic kicker before flushing disks and calling the exit callback.
The native bridge publishes the terminal outcome before changing its state
to stopped. Guest shutdown, restart, host stop, panic and execution failures
remain distinguishable; a generic dispatcher `HALT` is not sufficient to
identify a normal shutdown.

The session view removes guest input controls, releases captured input, restores
normal device sleep and shows a terminal message. `BootDisplay` keeps watching
the VM state after GPU rendering begins, then removes the last rendered frame
on both the device and an external display. Starting another guest, including
after a guest restart request, still requires quitting and reopening Henge.

## Regression checks

On an Apple Silicon Mac:

```sh
make build/test_shutdown build/test_exc build/test_devices
build/test_shutdown
build/test_exc
build/test_devices
```

`test_shutdown` executes guest HVC instructions with other CPUs already parked,
including CPU 0. It covers shutdown and reset from CPU 0 and a secondary, no
further guest instructions after a power request, preservation of the terminal
reason during host cleanup, and cancellation of pending CPU_ON calls. Waits
are bounded, with cleanup to release threads even when the regression fails.

## Validation on 2026-11-08

Base: upstream `ba9392e7ce13c6e80f2a635cf4a10336f27c0964`.

- Before the fix, the four parked-CPU power-request cases produced eight
  failures: parked threads remained asleep. After the fix, all shutdown tests
  passed on macOS and iOS Simulator.
- Exception tests: 52 checks passed on macOS and iOS Simulator. Device tests:
  97 checks passed on macOS. The complete Swift app and both renderer targets
  compiled; the existing display checks passed. The device Release app built.
- A separate iOS Simulator harness linked the production CPU/device engine,
  native bridge, `BootDisplay` and `StoppedMacView`. Its simulator JIT adapter
  replaces the physical device's debugger handoff. It booted a real macOS
  15.6.1 (24G90) guest with four software CPUs, then ran `/sbin/shutdown -h now`
  inside the guest. The log recorded PSCI SYSTEM_OFF from CPU 1, followed by
  the app exit callback; state was stopped, outcome was guest shutdown, active
  CPUs were zero and the block count stopped increasing. The rendered view
  showed "Mac shut down" with the old guest display removed.
- A separate guest run executed `/sbin/shutdown -r now`. It reached PSCI
  SYSTEM_RESET from CPU 0, exited with zero active CPUs and displayed
  "Mac requested a restart", including the existing reopen-to-start limitation.
- Simulator guest Metal rendering was disabled because its buffer-backed
  texture implementation rejected the production renderer's storage mode.
  The device package retains normal graphics. This validates the real guest
  shutdown and the shared stopped view, not physical-device GPU rendering or
  the complete SessionView layout on the phone. Physical-device testing of
  the new package remains pending.
