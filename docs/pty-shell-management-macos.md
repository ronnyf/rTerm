# PTY and Shell Process Management on macOS

**Date:** 2026-04-09
**Context:** Lessons learned from building rTerm's PTY layer and studying iTerm2 (Obj-C), wezterm (Rust), and Apple's Terminal.app (Obj-C).

## PTY Creation

Three approaches on macOS:

**`forkpty()` (Apple Terminal's approach):** Combines PTY creation AND fork in a single call. The simplest option — handles openpty + fork + setsid + slave setup atomically. The child gets stdin/stdout/stderr already connected to the PTY secondary.

```c
pid = forkpty(&masterFD, ttyPath, NULL, &winsize);
if (pid == 0) {
    // Child — already has new session + controlling terminal
    // Just configure termios and exec
    execvp(shell, argv);
}
```

**`openpty()` (iTerm2 and wezterm):** Creates the PTY pair without forking. Caller handles fork/exec separately. More flexible for complex setups (daemon architectures, pre-exec hooks).

```c
openpty(&master, &slave, ttyName, &termios, &winsize);
```

**`posix_openpt/grantpt/unlockpt` (rTerm's current approach):** Three-step creation with explicit control. Most verbose but portable.

```c
int master = posix_openpt(O_RDWR | O_NOCTTY);
grantpt(master);
unlockpt(master);
char *slaveName = ptsname(master);
int slave = open(slaveName, O_RDWR);
```

Both work. `openpty()` is more convenient; the manual approach gives finer control. iTerm2 and wezterm use `openpty()`. Apple Terminal uses `forkpty()` which is the simplest overall.

**CLOEXEC (wezterm pattern):** Set `FD_CLOEXEC` on both FDs immediately after creation so they don't leak to unrelated child processes. Only the FDs explicitly dup'd to 0/1/2 survive exec.

## Shell Spawning: Four Approaches

**Critical distinction:** The ability to run setup code in the child process *before* exec determines how much control you have over the shell's session and terminal.

### 1. forkpty() (Apple Terminal — simplest)

Combines PTY creation + fork + setsid + dup2 in one call. The child already has a new session, controlling terminal, and stdin/stdout/stderr connected. Just configure termios and exec:

```c
pid = forkpty(&masterFD, ttyPath, NULL, &winsize);
if (pid == 0) {
    // Child — session leader, controlling terminal set, FDs ready
    tcsetattr(0, TCSANOW, &customTermios);  // Configure terminal
    chdir(homeDir);
    execvp(shell, argv);
}
```

Apple Terminal also uses an **exec verification pipe**: a pipe with `FD_CLOEXEC` created before fork. The parent reads from it — if data arrives, exec failed (child wrote error); if read returns 0, exec succeeded (CLOEXEC closed the pipe).

### 2. Foundation's Process / posix_spawn (rTerm — current)

`posix_spawn` creates the child in a single step — no window to execute code before exec. Cannot call `setsid()`, `TIOCSCTTY`, or `setpgid()` in the child.

**Workaround:** Call `tcsetpgrp()` from the parent after spawn.

### 3. fork/exec (iTerm2)

Direct fork allows pre-exec setup in the child:

```c
pid_t pid = fork();
if (pid == 0) {
    // Child — runs before exec
    setsid();                        // New session, become session leader
    ioctl(slave, TIOCSCTTY, NULL);   // Set controlling terminal
    setpgid(getpid(), getpid());     // New process group
    tcsetpgrp(0, getpid());          // Become foreground group
    dup2(slave, 0);                  // stdin
    dup2(slave, 1);                  // stdout
    dup2(slave, 2);                  // stderr
    close(slave);
    close(master);
    execvp(shell, argv);
}
```

### 4. Command with pre_exec hook (wezterm / Rust)

Rust's `std::process::Command` supports a `pre_exec` closure that runs in the child after fork but before exec — the best of both worlds:

```rust
cmd.pre_exec(move || {
    // Reset signal handlers to defaults
    for sig in &[SIGCHLD, SIGHUP, SIGINT, SIGQUIT, SIGTERM, SIGALRM] {
        libc::signal(*sig, libc::SIG_DFL);
    }
    // Unblock all signals
    let empty: libc::sigset_t = std::mem::zeroed();
    libc::sigprocmask(SIG_SETMASK, &empty, std::ptr::null_mut());
    // New session + controlling terminal
    libc::setsid();
    libc::ioctl(0, TIOCSCTTY, 0);
    // Close leaked FDs (macOS Big Sur+ issue)
    close_random_fds();
    Ok(())
});
```

**Swift equivalent:** Foundation's `Process` has no `pre_exec` hook. To get this capability in Swift, you must use `fork/exec` directly or write a C helper.

**Workaround when using Foundation's Process:** Call `tcsetpgrp()` from the parent after `process.run()` to set the child as the terminal's foreground group. This prevents bash/sh from stopping itself with SIGTSTP.

## Job Control and Foreground Process Groups

When a shell starts, it checks if its process group is the terminal's foreground group. If not, it sends itself `SIGTSTP` (or `SIGTTIN`/`SIGTTOU`) and stops, waiting to be foregrounded.

**The fix (from iTerm2, copied from bash):**

```c
// Block signals that could interfere with tcsetpgrp
sigset_t block;
sigemptyset(&block);
sigaddset(&block, SIGTTIN);
sigaddset(&block, SIGTTOU);
sigaddset(&block, SIGTSTP);
sigaddset(&block, SIGCHLD);

sigset_t saved;
sigprocmask(SIG_BLOCK, &block, &saved);
tcsetpgrp(fd, shell_pid);
sigprocmask(SIG_SETMASK, &saved, NULL);
```

**rTerm's simpler approach** (works from parent with Foundation's Process):

```swift
tcsetpgrp(pty.primary.rawValue, process.processIdentifier)
```

This works because the parent calls it immediately after `process.run()`, before the shell has a chance to check and stop itself.

**wezterm's approach (in-child via pre_exec):** No explicit `tcsetpgrp()` needed — `setsid()` + `TIOCSCTTY` in the child establishes the shell as session leader with a controlling terminal, so job control works naturally.

## Signal Handling in Child Processes

Three strategies observed:

**iTerm2 (block in parent):** Block SIGTTIN/SIGTTOU/SIGTSTP/SIGCHLD before `tcsetpgrp()`, restore after. Prevents race conditions when the parent sets the foreground group.

**wezterm (reset in child):** Reset all signal handlers to `SIG_DFL` and unblock all signals in the child's `pre_exec` hook. Simpler, and ensures the shell starts with a clean signal state regardless of what the parent was doing. Also handles signals inherited from the terminal emulator's own signal handling (e.g., custom SIGCHLD handler).

**Apple Terminal (pipe-based SIGCHLD):** The signal handler does only one thing: `write(signalPipe[1], "!", 1)`. A separate thread reads from the pipe and calls `wait3(WNOHANG)` in a loop. Child termination is dispatched to the main thread via GCD. This is the gold standard for async-signal-safe design — no Objective-C or malloc in the signal handler.

## XPC Services and Terminal Processes

**XPC services cannot properly host terminal sessions.** The issues:

1. **`setsid()` fails** — XPC services are managed by launchd and cannot create new sessions.
2. **`TIOCSCTTY` fails** — Without a new session, the controlling terminal cannot be set.
3. **Process group isolation** — The XPC service's process hierarchy doesn't support terminal job control.

**iTerm2's solution:** They don't use XPC for shell hosting. Instead, they launch a **standalone daemon process** (`iterm2 --server`) that:
- Runs in the per-user bootstrap namespace (not the GUI/Aqua session)
- Has full control over process groups and sessions
- Communicates with the main app over Unix domain sockets
- Handles fork/exec with proper setsid()/TIOCSCTTY in the child

**rTerm's current approach:** Uses XPC but works around the limitations by calling `tcsetpgrp()` from the parent after spawn. This is sufficient for basic operation but doesn't provide full job control (Ctrl+Z, background processes).

## TERM Environment Variable

| Value | When to use |
|-------|------------|
| `dumb` | No escape sequence support — shell emits plain text only |
| `xterm` | Basic ANSI support (colors, cursor movement) |
| `xterm-256color` | Full 256-color support (iTerm2's default) |

iTerm2 also sets: `COLORTERM=truecolor`, `TERM_PROGRAM=iTerm.app`, `LC_TERMINAL=iTerm2`, custom `TERMINFO_DIRS` for bundled terminfo.

wezterm also sets: `COLORTERM=truecolor`, `TERM_PROGRAM=WezTerm`, `TERM_PROGRAM_VERSION=<version>`.

Apple Terminal uses a fallback chain: `xterm-256color` → `xterm` → `vt100` → `unknown`, validated via `tgetent()` before use. Sets `COLORTERM=truecolor` when direct color is enabled.

## I/O Architecture

**Apple Terminal's pattern (recommended):**
- Dedicated I/O thread running `select()` on all PTY master FDs
- Read: 4096 bytes per iteration, accumulated into a queue
- Main thread processes queued data asynchronously via `performSelectorOnMainThread:`
- **Write throttling:** Max 1024 bytes per chunk with 0.1s delay between chunks (prevents overwhelming the terminal with large pastes)
- **Backpressure:** Suspends reads if buffer exceeds 5MB

This separation keeps the main thread responsive and the I/O thread efficient. rTerm currently uses `FileHandle.readabilityHandler` which dispatches to a GCD queue — functionally similar but without throttling or backpressure.

## Termios Configuration

iTerm2's default termios flags (from `iTermTTYState.c`):

```
c_iflag: ICRNL | IXON | IXANY | IMAXBEL | BRKINT | IUTF8
c_oflag: OPOST | ONLCR
c_cflag: CREAD | CS8 | HUPCL
c_lflag: ICANON | ISIG | IEXTEN | ECHO | ECHOE | ECHOK | ECHOKE | ECHOCTL
```

Key flags:
- `ICRNL` — translate CR to NL on input (Enter key produces newline for the shell)
- `ONLCR` — translate NL to CR+NL on output (programs that emit bare `\n` render correctly)
- `ECHO` — kernel echoes characters (the echo we see before the shell processes input)
- `ICANON` — canonical (line-buffered) mode
- `ISIG` — enable signal characters (Ctrl+C → SIGINT, Ctrl+Z → SIGTSTP)
- `IUTF8` — UTF-8 aware line editing

## File Descriptor Handoff Pattern

After fork, the child needs exactly these FDs:
- 0: PTY secondary (stdin)
- 1: PTY secondary (stdout)
- 2: PTY secondary (stderr)

iTerm2 also passes:
- 3: Unix socket for server communication
- Dead man's pipe (closes if server dies, shell detects orphan)

All other FDs should be closed in the child (`closefrom(3)` or equivalent).

## File Descriptor Leaks (macOS Big Sur+)

**Discovered by wezterm:** macOS Big Sur and later leak file descriptors to child processes (from system frameworks, Cocoa, etc.). If not closed, leaked FDs can cause issues — security concerns, resource exhaustion, and unexpected behavior in shells.

**wezterm's fix:** In the child's pre_exec hook, enumerate `/dev/fd` and close everything above FD 2:

```rust
fn close_random_fds() {
    if let Ok(dir) = std::fs::read_dir("/dev/fd") {
        let fds: Vec<c_int> = dir.filter_map(|e| {
            e.ok()?.file_name().into_string().ok()?.parse().ok()
        }).filter(|&fd| fd > 2).collect();
        for fd in fds { unsafe { libc::close(fd); } }
    }
}
```

**Prevention:** Set `FD_CLOEXEC` on all FDs you create (both PTY ends, sockets, pipes). This ensures they auto-close on exec. Only explicitly dup'd FDs (0, 1, 2) survive.

## Performance: tcgetpgrp() Is Expensive

**Discovered by wezterm:** `tcgetpgrp()` takes ~700μs per call. With multiple tabs, querying foreground process for each tab (e.g., to update tab titles) causes visible stuttering.

**Solution:** Cache the foreground PID and CWD with a 300ms TTL:

```
struct CachedLeaderInfo {
    updated: Instant
    pid: pid_t
    path: String?
    cwd: String?
}
// Only refresh if > 300ms since last update
```

## Process Monitoring

**Apple Terminal's approach:**
- `tcgetpgrp(masterFD)` to get the foreground process group
- `proc_pidinfo()` to enumerate child processes
- **Dirty process detection:** A non-shell process with controlling TTY is "dirty" (unsaved work). Shell in foreground group + TTY not in `ICANON` mode = "busy" (running a pipeline). This is how Terminal.app decides whether to warn on close.

## Future Considerations for rTerm

1. **Replace Foundation's Process with forkpty()** — Apple Terminal's approach is the simplest: `forkpty()` handles PTY creation + fork + session setup in one call. This is the recommended migration path for rTerm. Both iTerm2 and wezterm also do their own fork/exec.
2. **Add exec verification pipe** — Apple Terminal's pattern: pipe with CLOEXEC before fork, parent reads to detect exec failure. Race-free.
3. **Consider a daemon architecture** — If XPC limitations become blocking (e.g., for Ctrl+Z support), a standalone daemon like iTerm2's approach would be more robust. wezterm uses a mux server daemon with double-fork for daemonization.
4. **Custom termios initialization** — Set explicit termios flags rather than relying on PTY defaults. Apple Terminal carefully configures IUTF8, echo flags, and control characters.
5. **Signal blocking around tcsetpgrp()** — Block SIGTTIN/SIGTTOU/SIGTSTP before calling tcsetpgrp() to avoid race conditions (iTerm2 does this, copied from bash).
6. **Close leaked FDs in child** — macOS Big Sur+ leaks FDs. Enumerate /dev/fd and close all > 2 after fork (wezterm pattern).
7. **Cache tcgetpgrp() results** — Implement a TTL cache (~300ms) for foreground process queries to avoid UI stuttering with multiple tabs (wezterm pattern).
8. **Add I/O throttling** — Write throttling (1024 bytes/chunk, 0.1s delay) and backpressure (suspend reads at 5MB) per Apple Terminal's pattern.
9. **Pipe-based SIGCHLD handling** — Use a self-pipe for signal-safe child termination detection (Apple Terminal pattern).
10. **Dirty process detection** — Check ICANON mode + foreground group to warn on close (Apple Terminal pattern).

## Reference: Comparison of Approaches

| Aspect | rTerm (Swift) | Apple Terminal (Obj-C) | iTerm2 (Obj-C) | wezterm (Rust) |
|--------|--------------|----------------------|----------------|----------------|
| PTY creation | posix_openpt | forkpty() | openpty() | openpty() |
| Process spawn | Foundation Process | forkpty() + exec | fork/exec | Command + pre_exec |
| setsid() | Cannot (posix_spawn) | Automatic (forkpty) | In child | In child pre_exec |
| TIOCSCTTY | Removed (failed) | Automatic (forkpty) | In child | In child pre_exec |
| Foreground group | tcsetpgrp() from parent | Automatic | In child | Implicit via setsid |
| Signal handling | None | Pipe-based SIGCHLD | Block in parent | Reset in child |
| FD cleanup | Manual close secondary | N/A (forkpty handles) | closefrom(3) | Enumerate /dev/fd |
| I/O model | FileHandle readabilityHandler | select() thread + queue | Dispatch sources | Rust async I/O |
| Write throttling | None | 1024B chunks, 0.1s delay | Unknown | Unknown |
| Backpressure | None | Suspend at 5MB | Unknown | Unknown |
| Process isolation | XPC service | In-process | Standalone daemon | In-process |
| TERM default | dumb | xterm-256color (validated) | xterm (configurable) | xterm-256color |
| Exec verification | None | CLOEXEC pipe | Unknown | Unknown |
