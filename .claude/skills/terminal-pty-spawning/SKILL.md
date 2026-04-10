---
name: terminal-pty-spawning
description: Use when creating PTY pairs, spawning shell processes, or debugging terminal I/O on macOS — covers forkpty vs posix_spawn, job control SIGTSTP, foreground process groups, XPC limitations, and environment setup
---

# Terminal PTY and Shell Spawning on macOS

## Overview

Spawning a shell inside a pseudo-terminal on macOS requires coordinating PTY creation, process group management, signal handling, and I/O plumbing. The critical invariant: **the shell must be the terminal's foreground process group, or it will stop itself with SIGTSTP.**

## When to Use

- Creating a PTY pair for a terminal emulator
- Spawning a shell process connected to a PTY
- Debugging "shell starts but produces no output"
- Debugging "shell echoes characters but doesn't execute commands"
- Setting up terminal I/O in an XPC service or daemon
- Choosing between `forkpty()`, `openpty()`, `posix_openpt()`, or Foundation's `Process`

## PTY Creation: Choose Your Level

| Function | What it does | Use when |
|----------|-------------|----------|
| `forkpty()` | PTY + fork + setsid + dup2 in one call | You want the simplest path (recommended) |
| `openpty()` | PTY pair only, you handle fork | You need custom fork logic (daemon, pre-exec hooks) |
| `posix_openpt()` + `grantpt()` + `unlockpt()` | Manual three-step creation | You need maximum control or portability |

All three produce the same result: a primary/secondary FD pair. `forkpty()` does the most work for you.

## The Foreground Process Group Problem

**Symptom:** Shell starts (valid PID, `isRunning=true`), characters echo back (PTY line discipline handles echo), but no prompt appears and commands don't execute.

**Root cause:** The shell calls `tcgetpgrp()` on startup to check if it's the terminal's foreground process group. If not, it sends itself `SIGTSTP` and stops. The PTY line discipline continues echoing (it's kernel-side), which makes it look like the shell is working.

**Diagnosis:** Use `sample <pid> 1` — a stopped shell shows `__kill` in the call stack.

### Fix by spawn method:

**If using `forkpty()`:** The child is already a session leader with a controlling terminal. Call `tcsetpgrp(0, getpid())` in the child before exec. Block SIGTTIN/SIGTTOU/SIGTSTP first:

```c
// In child, after forkpty(), before exec
sigset_t block, saved;
sigemptyset(&block);
sigaddset(&block, SIGTTIN);
sigaddset(&block, SIGTTOU);
sigaddset(&block, SIGTSTP);
sigprocmask(SIG_BLOCK, &block, &saved);
tcsetpgrp(STDIN_FILENO, getpid());
sigprocmask(SIG_SETMASK, &saved, NULL);
```

**If using `openpty()` + `fork()`:** Call `setsid()` + `ioctl(slave, TIOCSCTTY, 0)` + `tcsetpgrp()` in the child.

**If using Foundation's `Process` (posix_spawn):** No child pre-exec hook available. Call `tcsetpgrp()` from the parent immediately after `process.run()`:

```swift
try process.run()
tcsetpgrp(pty.primary.rawValue, process.processIdentifier)
```

This works because you call it before the shell has time to check and stop itself. It's a race you'll win in practice but it's not guaranteed — `forkpty()` is more robust.

## XPC Services Are Wrong for Shell Hosting

**Do not host shell processes in XPC services.** Three things break:

1. `setsid()` fails — XPC services are managed by launchd and cannot create new sessions
2. `TIOCSCTTY` fails — without a new session, controlling terminal cannot be set
3. Process group isolation — the XPC hierarchy doesn't support terminal job control

**Alternatives:**
- Host the shell in-process (simplest)
- Launch a standalone daemon that does fork/exec (most robust)
- Use XPC with the `tcsetpgrp()` workaround (works for basic use, no Ctrl+Z)

## Shell Environment Setup

**TERM value:** Use `dumb` if your parser doesn't handle ANSI escape sequences. Use `xterm-256color` once it does. Validate via `tgetent()` before setting.

**Minimum environment:**
```
TERM=dumb (or xterm-256color)
HOME=<user home from getpwuid>
PATH=/usr/bin:/bin:/usr/local/bin
SHELL=<path to shell>
LANG=<user's locale>
```

**Shell flags for startup:**
- bash: `--norc --noprofile` to skip rc files during development. Remove once stable.
- zsh: `-f` to skip `.zshrc`. Remove once stable.
- Both: avoid `-i` unless you've solved the foreground group problem — interactive mode enables job control which triggers the SIGTSTP issue.

## I/O Architecture

**Read path:** PTY primary FD → readability handler (background queue) → async stream → parser → screen model → renderer.

**Write path:** Keyboard event → encoder → PTY primary FD write.

**Throttling (recommended for paste):** Cap write chunks at 1024 bytes with 100ms delay between chunks. Prevents overwhelming the shell with large pastes.

**Backpressure (recommended):** Suspend reads if unprocessed buffer exceeds ~5MB. Prevents memory issues with programs that produce output faster than the renderer can consume.

## File Descriptor Hygiene

- Set `FD_CLOEXEC` on all FDs you create. Only explicitly dup'd FDs (0, 1, 2) should survive exec.
- Close the secondary FD in the parent after the child has started — the child has its own copy.
- macOS Big Sur+ leaks FDs from system frameworks. In the child, enumerate `/dev/fd` and close everything > 2 before exec.

## Common Mistakes

| Mistake | Symptom | Fix |
|---------|---------|-----|
| Not setting foreground group | Shell echoes but doesn't execute | `tcsetpgrp()` — see section above |
| Using `-i` flag without foreground group | Shell stops immediately | Remove `-i` or fix foreground group first |
| XPC service hosting shell | `setsid()` fails, no controlling terminal | Move to in-process or daemon |
| Relying on `.bashrc`/`.zshrc` | Shell hangs on startup (plugins + dumb TERM) | Use `--norc`/`-f` during development |
| Not closing secondary FD in parent | Shell may not detect EOF on exit | Close after `process.run()` / fork |
| `tcgetpgrp()` in hot path | ~700us per call, UI stuttering with tabs | Cache with 300ms TTL |

## Diagnostic Checklist

When shell output doesn't work:

1. **Is the process alive?** `kill -0 <pid>` or check `process.isRunning`
2. **Is it stopped?** `sample <pid> 1` — look for `__kill` in the stack
3. **Are FDs connected?** `lsof -p <pid>` — stdin/stdout/stderr should point to `/dev/ttysNNN`
4. **Is the echo from the shell or the PTY?** PTY echo (kernel) works even when shell is stopped. If you see echo but no prompt, the shell is likely stopped.
