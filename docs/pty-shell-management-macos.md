# PTY and Shell Process Management on macOS

**Date:** 2026-04-09
**Context:** Lessons learned from building rTerm's PTY layer and studying iTerm2's implementation.

## PTY Creation

Two approaches on macOS:

**`openpty()` (iTerm2's approach):** Single call that creates the PTY pair, sets termios and winsize atomically. Simpler but less control over individual steps.

```c
openpty(&master, &slave, ttyName, &termios, &winsize);
```

**`posix_openpt/grantpt/unlockpt` (rTerm's approach):** Three-step creation with explicit control. Requires manual `ptsname()` to get the secondary device name.

```c
int master = posix_openpt(O_RDWR | O_NOCTTY);
grantpt(master);
unlockpt(master);
char *slaveName = ptsname(master);
int slave = open(slaveName, O_RDWR);
```

Both work. `openpty()` is more convenient; the manual approach gives finer control.

## Shell Spawning: fork/exec vs. posix_spawn

**Critical distinction:** Foundation's `Process` (NSTask) uses `posix_spawn` internally. `posix_spawn` creates the child in a single step — there is no window to execute code in the child before exec. This means you **cannot** call `setsid()`, `TIOCSCTTY`, or `setpgid()` in the child.

**iTerm2 uses fork/exec directly**, which allows pre-exec setup in the child:

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

## Future Considerations for rTerm

1. **Replace Foundation's Process with fork/exec** — Enables proper setsid()/TIOCSCTTY in the child, full job control, and signal handling.
2. **Consider a daemon architecture** — If XPC limitations become blocking (e.g., for Ctrl+Z support), a standalone daemon like iTerm2's approach would be more robust.
3. **Custom termios initialization** — Set explicit termios flags rather than relying on PTY defaults. Ensures consistent behavior across macOS versions.
4. **Signal blocking around tcsetpgrp()** — Block SIGTTIN/SIGTTOU/SIGTSTP before calling tcsetpgrp() to avoid race conditions (iTerm2 does this, copied from bash).
