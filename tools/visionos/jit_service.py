"""Gives an app on a paired Apple Vision Pro (or any CoreDevice device) JIT from this Mac.

Attaches LLDB to the app and services the BreakpointJIT traps the way Henge's
ios/Henge/Resources/henge-jit.js does under StikJIT, over the same debugserver packets:

  brk #0x69                  -> x0 = 0xE0000069 ("a script-servicing debugger is attached")
  brk #0xf00d, x16 = 1       -> _M<x1>,rx allocates the region, one byte is written into
                                each 16 KB page (what makes the pages executable under TXM),
                                x0 = its address
  brk #0xf00d, x16 = 0       -> detach

Run it through run_jit.sh, which finds (or launches) the process and Xcode's LLDB Python. It is a
standalone SBDebugger in synchronous mode: a loop inside the lldb driver never sees
the stops, because the driver's own event thread takes them.
"""
import os
import re
import sys
import time

import lldb

PAGE = 16384


def packet(debugger, text):
    res = lldb.SBCommandReturnObject()
    debugger.GetCommandInterpreter().HandleCommand(f"process plugin packet send '{text}'", res)
    m = re.search(r"response:\s*(\S*)", res.GetOutput() or "")
    return m.group(1) if m else ""


def log(text):
    print(f"[jit] {text}", flush=True)


def prepare_region(debugger, size):
    reply = packet(debugger, f"_M{size:x},rx")
    log(f"_M{size:x},rx -> {reply!r}")
    try:
        addr = int(reply, 16)
    except ValueError:
        return 0
    pages = (size + PAGE - 1) // PAGE
    started, bad = time.time(), 0
    if os.environ.get("JIT_BLESS", "bulk") == "bulk":
        # The whole region in large writes: every page written by the debugger, in fewer round trips than one
        # write a page (on Wi-Fi about 1.6 MB/s against 42 pages/s, so 16 MB takes 10 s instead of 25).
        # JIT_BLESS=page writes one byte a page, as StikJIT does.
        chunk = int(os.environ.get("JIT_BLESS_CHUNK", str(1 << 20)))
        fill = b"\x69" * chunk
        process = debugger.GetSelectedTarget().GetProcess()
        for offset in range(0, size, chunk):
            n = min(chunk, size - offset)
            err = lldb.SBError()
            if process.WriteMemory(addr + offset, fill[:n], err) != n or err.Fail():
                # Once one fails the connection is usually gone (the headset slept, say): stop, and say why.
                log(f"write at +{offset >> 20} MB failed: {err.GetCString()}; process state {process.GetState()}")
                return 0
            done = offset + n
            if done % (64 << 20) == 0:
                rate = done / (time.time() - started)
                log(f"  {done >> 20}/{size >> 20} MB, {rate / 1e6:.1f} MB/s, about {(size - done) / rate:.0f} s left")
        log(f"wrote all {size >> 20} MB ({pages} pages) in {time.time() - started:.1f} s")
        return addr
    for page in range(pages):
        if packet(debugger, f"M{addr + page * PAGE:x},1:69") != "OK":
            bad += 1
        if page and page % 4096 == 0:
            rate = page / (time.time() - started)
            log(f"  {page}/{pages} pages, {rate:.0f}/s, about {(pages - page) / rate:.0f} s left")
    log(f"wrote one byte into {pages} pages in {time.time() - started:.1f} s ({bad} not OK)")
    return addr


def set_register(debugger, thread, name, value):
    """Writes a register of the stopped thread with the packet henge-jit.js sends,
    P<register number>=<little-endian value>;thread:<tid>; LLDB's own register writes fail
    after attaching to an app launched suspended, while debugserver takes this packet."""
    number = {"x0": 0, "pc": 0x20}[name]
    reply = packet(debugger, f"P{number:x}={value.to_bytes(8, 'little').hex()};thread:{thread.GetThreadID():x};")
    if reply != "OK":
        log(f"could not set {name} to {value:#x}: {reply!r}")
    return reply == "OK"


def handle_stop(debugger, process):
    """Services one stop. Returns False once the app asked to detach."""
    thread = next((t for t in process
                   if t.GetStopReason() in (lldb.eStopReasonException, lldb.eStopReasonBreakpoint)), None)
    if thread is None:
        return True  # the attach stop, or a signal: just continue
    process.SetSelectedThread(thread)
    frame = thread.GetFrameAtIndex(0)
    pc = frame.GetPC()
    insn = process.ReadUnsignedFromMemory(pc, 4, lldb.SBError())
    imm = (insn >> 5) & 0xFFFF if (insn & 0xFFE0001F) == 0xD4200000 else None
    x16, x0, x1 = (frame.FindRegister(n).GetValueAsUnsigned() for n in ("x16", "x0", "x1"))
    if imm == 0x69:
        set_register(debugger, thread, "x0", 0xE0000069)
        log("brk #0x69: answered E0000069")
    elif imm == 0xF00D and x16 == 1:
        if x0 == 0 and x1 == 0:
            log("brk #0xf00d prepare with no size: nothing to do")
        else:
            set_register(debugger, thread, "x0", x0 or prepare_region(debugger, x1))
    elif imm == 0xF00D and x16 == 0:
        set_register(debugger, thread, "pc", pc + 4)
        log("detach requested: detaching")
        process.Detach()
        return False
    else:
        log(f"stop at {pc:#x} ({thread.GetStopDescription(200)}), not a JIT trap: passing it on")
        return True
    if not set_register(debugger, thread, "pc", pc + 4):
        log("the app would run the same brk again: giving up")
        process.Detach()
        return False
    return True


def main(pid, device):
    lldb.SBDebugger.Initialize()
    debugger = lldb.SBDebugger.Create()
    debugger.SetAsync(False)
    ci = debugger.GetCommandInterpreter()
    for cmd in ("settings set plugin.process.gdb-remote.packet-timeout 30",
                "settings set target.memory-module-load-level minimal",
                "settings set symbols.load-on-demand true",
                f"device select {device}",
                f"device process attach --pid {pid}"):
        res = lldb.SBCommandReturnObject()
        ci.HandleCommand(cmd, res)
        # `device select` reports no success status even when it works: only the attach decides.
        if res.GetError().strip():
            log(f"{cmd}: {res.GetError().strip()}")
    process = debugger.GetSelectedTarget().GetProcess()
    if not process.IsValid() or process.GetState() != lldb.eStateStopped:
        log(f"could not attach to pid {pid}")
        return 1
    log(f"attached to pid {pid}")
    while process.GetState() == lldb.eStateStopped:
        if not handle_stop(debugger, process):
            log("done")
            return 0
        process.Continue()  # synchronous: returns at the next stop
    log(f"process left: state {process.GetState()}, exit status {process.GetExitStatus()}")
    return 1


if __name__ == "__main__":
    sys.exit(main(int(sys.argv[1]), sys.argv[2]))
