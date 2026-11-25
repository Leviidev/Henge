# A coding terminal on the iPhone, without macOS

Henge's **Mac Apps** runs Mac programs through its own loader, with no virtual Mac started. This adds a **terminal** to
it, and a **toolchain that runs in the same process**: a command-line coding program (Claude Code is the one tried) can
edit a project, compile it, link it into an iPhone app, run it without a window and read what it did, all on the phone.

- **No macOS, no virtual machine, no remote computer** for the building. (Claude Code itself still talks to its service.)
- **Off by default**: Henge › Settings › **Mac apps without macOS**.
- **Nothing in `core/`**: the engine, the virtual Mac and Linux machines run as before.

**Credits:** Henge, its engine and the Mac Apps loader this builds on (`tl/`) are Leviidev's and Henge's contributors'. The
terminal and toolchain were added by Tomba247.

## How to use it

You need an iPhone or iPad that Henge runs on with JIT, a Mac once (to make the toolchain), and your own copy of the
program you want in the terminal.

1. **Make the toolchain**, on a Mac with Xcode and Homebrew's `python`, `ninja` and `cmake`:
   `zsh tools/phone-kit/make_toolchain.sh ~/Toolchain` (set `BREW` to Homebrew's folder, such as `/opt/homebrew`).
   It copies Apple's compiler and iPhone SDK from your Xcode. They are Apple's: for your own use, **not to be shared**.
   Nothing in this repository contains them.
2. **Put it on the phone**: the folder goes in Files › On My iPhone › Henge › **Projects** › **Toolchain**.
3. **Turn on** Settings › **Mac apps without macOS**.
4. **Bring in the program** (Mac Apps): a program, an `.app`, or a `.dmg`, also one left in Files › Henge › Mac Apps. For Claude
   Code, its macOS arm64 program file by itself (the `claude` in Anthropic's macOS download). It is not included: it is
   Anthropic's, under its own licence.
5. **Open in a Terminal.** Sign in the way the program asks; that is between you and it.
6. Ask for something: "make an app that…", "build this and fix the errors". The result is an **unsigned `.ipa`** in the
   project's folder, to sign with whatever you sign Henge with.

One program runs per launch. Quit Henge to run another, or to start a Mac.

## How it works

```
 iPhone app process (the only one: iOS allows no fork and no exec)
 ┌──────────────────────────────────────────────────────────────────────────┐
 │ MacTerminal + TerminalScreen   the screen, keys, paste and selection     │
 │        │ keystrokes / output over a socketpair                           │
 │ henge-tl-term.c                a pretend tty, spawn, wait and keychain   │
 │        │                                                                 │
 │ Claude Code (Mach-O, arm64)    loaded by tl/, its JavaScript interpreted │
 │        │ MCP over HTTP, 127.0.0.1 only, secret made at each launch       │
 │ ToolServer                     build · run_command · search · …          │
 │        │                                                                 │
 │ ProjectMaker / ProjectBuilder  henge-project.json → units → link → IPA   │
 │        │ henge_tl_tool_run                                               │
 │ tl_tool.h                      clang · ld · swift-frontend · cmake ·     │
 │                                ninja · python3 · sh · what you built     │
 └──────────────────────────────────────────────────────────────────────────┘
```

### The loader (`tl/loader`)

`tl` maps a Mac program's Mach-O images into Henge's own process and binds them to iOS's frameworks and to its stand-ins.
The code is already arm64 and runs as it is; it is neither translated nor emulated. What this work adds to it:

- Libraries are found the way dyld does it: a bare `@loader_path` or `@executable_path`, the search paths of the images
  that load a library, and a library already loaded under the same install name. Xcode's Swift compiler needs all three.
- `first_lookup`: a host's own answer for a symbol can come before the loader's general one.

### A pretend terminal (`henge-tl-term.c`, `MacTerminal.swift`, `TerminalScreen.swift`)

iOS gives apps no pseudo-terminal. The program's input and output are one end of a socket; `isatty`, `tcgetattr`,
`ioctl(TIOCGWINSZ)` and the rest answer for it. `TerminalScreen` is a small terminal emulator written for this: colours,
the alternate screen, scrolling regions, wide characters, links, and OSC 52 for the clipboard. It keeps track of wrapped
rows, so a link across several rows opens and copies whole.

- **Paste** uses the system's paste control, as iOS refuses an app that reads another app's text by itself.
- **Keys** a phone keyboard lacks (Esc, Tab, Control, arrows) are in a row that scrolls, with Hide always in reach.
- **Web pages** a program wants opened are asked about first.

Claude Code is a Bun program. Bun's JavaScript JIT is turned off and the interpreter runs.

### Saving a sign-in

On a Mac, Claude Code keeps its sign-in by running `/usr/bin/security`. iOS has no such program, and an app cannot start
one. Henge's answer is a `security` that holds no items and refuses to add any, with the real tool's exit codes. Claude
Code then uses its own fallback, a private file (mode 0600) in Henge's Application Support. Henge never reads it; its log
records that each step happened and never an argument.

### A toolchain in one process (`tl/loader/tl_tool.h`)

A compiler expects a new process each time: it registers its options once, frees little, and ends with `exit`. Here:

1. Each tool image is loaded once. Its writable data is **snapshotted before its initializers run**, put back before
   each run, and the initializers then run again.
2. Each run has **a malloc zone of its own**, destroyed afterwards. Files, maps, thread keys and C++ streams it left are
   let go.
3. `exit`, `abort` and `_exit` **end the run**, not the app. Its other threads end at their next wait.
4. `posix_spawn`, `posix_spawnp`, `system`, `popen`, pipes, `wait4`, `waitpid` and `kqueue` process events are answered
   inside the process. A "process" is a thread with its own arguments, environment, folder, standard files and a made-up
   process number. **CMake, Ninja and Python's `subprocess` therefore work**, with several tools at once.
5. Several copies of one tool run side by side in separate **namespaces**, so three compilers can work together.

`tools/phone-kit/sh.c` is a small POSIX-like shell made for this: pipes, `&&`, `||`, redirection, `if`, `for`, `while`,
`$(…)`, and built-in `cp`, `mv`, `rm`, `mkdir`, `ls`, `cat`, `head`, `tail`, `wc`.

### Address space

At launch Henge holds about 60 GB of an iPhone app's 64 GB of address space, for Mac apps whose allocators need a big
range. The terminal does not use it, and with it held there may be no room for a compiler. It is given back at the
first tool run. On an iPhone 18 Pro Max the log said there was no room for 512 MB before that, and room after.

### Projects (`ProjectMaker.swift`, `ProjectBuilder.swift`)

A project is a folder with a `henge-project.json`, which the coding program writes itself:

```json
{
  "name": "MyApp", "bundle_id": "com.example.myapp", "version": "1.0", "min_ios": "17.0",
  "sources": ["src/**/*.c", "ios/*.swift"],
  "include": ["include"], "frameworks": ["UIKit", "Metal"],
  "resources": ["assets"], "icon": "icon.png"
}
```

C, C++, Objective-C(++), assembly and Swift (with SwiftUI and macros). Builds are incremental by content hash and by the
compiler's dependency output. A project with its own build system gives `commands` instead
(`cmake -S . -B build/cm`, `ninja -C build/cm`) and names the program they make. `"kind": "tool"` makes a program to run
here. A very large project can come as a kit instead (below).

### Kits: a big project that is already mostly built

A phone can compile a small app from nothing in under a minute. A project of hundreds of files would take far longer,
and much of it never changes. A **kit** is such a project with the slow part already done on a Mac:

| In a kit | What it is |
|---|---|
| `source/` | The sources the build used, and every header they read |
| `build/` | The compiled objects and libraries from the Mac |
| `app/` | What goes in the app besides its program: pictures, data, `Info.plist` |
| `toolchain/` `sdk/` | The `clang`, `ld` and iPhone SDK it was built with |
| `henge-build.json` | Each source with its object and flags, what it depends on, and how to link, pack and run it |

`henge-build.json` holds a hash of every file an object was made from. On the phone, `build` compares them: if you
change one source, **only that one is compiled** (a header: the sources that read it), then everything is linked and
packed into a new IPA. Nothing is compiled when nothing changed. Moving the folder is fine, as paths are relative to it.

How to make one, on a Mac:

1. Build the project for the iPhone the usual way with CMake and Ninja.
2. `python3 tools/phone-kit/make_kit.py SOURCE BUILD TARGET APP KIT` (the source folder, the build folder, Ninja's
   target, the `.app` in the build folder, and the folder to make).
   - `--prebuilt TEXT` leaves out sources whose path has TEXT, such as a huge generated folder; their objects are used.
   - `--run FILE` says how the program runs without a window, so that the coding program can test it.
3. Zip it, send it to the phone, and put the folder in Files › Henge › **Projects**.

| | Project (`henge-project.json`) | Kit (`henge-build.json`) |
|---|---|---|
| Made by | The coding program, on the phone | `make_kit.py`, on a Mac |
| Needs a Mac | Only for the Toolchain, once | Yes, to make the kit |
| First build | Everything is compiled | Only what you changed |
| New source files | Yes | No: make the kit again |
| For | New apps, small and middle-sized projects | Large existing projects |

A kit holds Apple's compiler and SDK, and your project's code: for your own use, like the toolchain. No kits are in this
repository or its releases.

### The tools a coding program gets (`ToolServer.swift`)

| Tool | What it does |
|---|---|
| `build` | Compile what changed, link, pack the unsigned IPA, or return the errors |
| `run_command` | A shell line with the toolchain, and programs built here |
| `run_program` · `program_command` · `stop_program` | Run the build without its window, send it JSON commands, stop it |
| `search` · `find_files` | Regular-expression search, as `grep` and `find` are not there |
| `project_help` | The project format and what works, for the program to read first |
| `download` · `github_download` | Bring in source (zip, tar.gz, tar.xz, tar.bz2; submodules too) |
| `github_save` | Commit chosen files to a branch, never forced. Needs a token you add |

**Safety.** The server listens on 127.0.0.1 only, and a new secret is needed at every launch. Folders the tools write to
must be inside Projects. The optional GitHub token is kept in the iPhone's Keychain; while the program runs it is also in
a config file only Henge's own process can read. What the toolchain runs is native code in Henge's process and is **not
sandboxed from Henge**: run only source you trust, and look before allowing a coding program to run a command.

## What is tested, and what is not

| | State |
|---|---|
| Terminal, sign-in and saved sign-in | Used on an iPhone 18 Pro Max, iOS 27.0.1 |
| clang 21, the shell, Python 3.15 | Reported working on that iPhone by the coding program in it |
| A sample app built to an IPA | Reported on that iPhone: first build 28.7 s |
| `run_program` | It ran and ended with 0 on that iPhone; the output file was empty (not explained yet) |
| Swift, CMake, Ninja | On a Mac, in the same loader under iOS's rules; not checked on an iPhone |
| `download`, `github_download`, `github_save` | **Not tried against GitHub yet** |
| Mac apps that ran before (the rest of Mac Apps) | Still work, as used on that iPhone |
| Other iPhones, iPads, older iOS | **Not tried** |

Known gaps:

- Claude Code's own Bash tool does not work on the phone ("No suitable shell found"). `run_command` does the job.
- No `git`, `make`, `autoconf`, `sed`, `awk` or `grep`; no Xcode projects, storyboards, asset catalogs or CocoaPods; no
  Python packages with C parts; no `fork`. Python's process pools become threads.
- Programs here share about 1 GB in all. One that crashes takes Henge with it.
- `python3`, `clang` and the rest have no window: graphics are checked by having the program write a picture.

## Trying the code

`make build/test_tl_term build/test_project` builds the Mac-side tests (the terminal and the project tools);
`tests/test_terminal.swift` covers the screen. They run on a Mac, in the same loader.
