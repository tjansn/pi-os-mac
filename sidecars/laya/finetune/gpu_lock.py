#!/usr/bin/env python3
"""Non-blocking exclusive advisory lock for a coordinated local-GPU window.

Tom's local-inference coordination uses an exclusive `fcntl.flock` on a shared lock file
that model services hold for as long as they own the GPU. A fine-tune on MPS must take the
same lock for its whole run and must never wait for it: if another tenant holds it, refuse.

Acquiring the flock is necessary, not sufficient: a free lock does not prove the window is
yours. Agree on the window with the lock owner first (pi-os AGENTS.md, "Local inference
coordination"). This module never creates the lock file, never deletes it, and is only
used when the caller passes a lock path explicitly; no path is hard-coded.

  python3 gpu_lock.py --check PATH   exit 0 = free (taken and released), 75 = busy, 66 = missing

--check really takes the lock for a moment, so it is not a passive probe: never run it
against the shared lock while another tenant's reservation is active.
"""
import argparse
import errno
import os
import sys

EXIT_BUSY = 75  # EX_TEMPFAIL
EXIT_MISSING = 66  # EX_NOINPUT


class GpuLockBusy(Exception):
    """Another process holds the lock: refuse, never wait."""


class GpuLockMissing(Exception):
    """The lock file does not exist; it is the owner's to create, not ours."""


def acquire(path):
    """Open `path` read-only and take LOCK_EX | LOCK_NB. Returns the fd to hold for the whole run."""
    import fcntl  # POSIX only; Windows has no MPS and no shared lock file

    try:
        fd = os.open(path, os.O_RDONLY | getattr(os, "O_CLOEXEC", 0))
    except FileNotFoundError:
        raise GpuLockMissing(path)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError as error:
        os.close(fd)
        if error.errno in (errno.EWOULDBLOCK, errno.EAGAIN, errno.EACCES):
            raise GpuLockBusy(path)
        raise
    return fd


def release(fd):
    import fcntl

    try:
        fcntl.flock(fd, fcntl.LOCK_UN)
    finally:
        os.close(fd)


def main(argv=None):
    parser = argparse.ArgumentParser(description="Probe a GPU coordination lock without waiting")
    parser.add_argument("--check", required=True, metavar="PATH")
    args = parser.parse_args(argv)
    try:
        release(acquire(args.check))
    except GpuLockBusy:
        print("busy")
        return EXIT_BUSY
    except GpuLockMissing:
        print("missing")
        return EXIT_MISSING
    print("free")
    return 0


if __name__ == "__main__":
    sys.exit(main())
