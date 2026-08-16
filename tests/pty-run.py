#!/usr/bin/env python3
"""Drive an interactive command through a PTY, one prompt at a time."""

from __future__ import annotations

import argparse
import errno
import fcntl
import os
import pty
import select
import subprocess
import sys
import termios
import time


PROMPT_MARKERS = (
    "必须输入）: ".encode(),
    "必须输入]: ".encode(),
    "按回车键继续...".encode(),
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--transcript", required=True)
    parser.add_argument("--timeout", type=float, default=90.0)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if args.command[:1] == ["--"]:
        args.command = args.command[1:]
    if not args.command:
        parser.error("missing command after --")
    return args


def earliest_marker(buffer: bytearray, start: int) -> tuple[int, bytes] | None:
    matches = []
    for marker in PROMPT_MARKERS:
        index = buffer.find(marker, start)
        if index >= 0:
            matches.append((index, marker))
    return min(matches, default=None, key=lambda item: item[0])


def main() -> int:
    args = parse_args()
    responses = sys.stdin.buffer.read().decode("utf-8").splitlines()
    master_fd, slave_fd = pty.openpty()

    def make_controlling_terminal() -> None:
        os.setsid()
        fcntl.ioctl(0, termios.TIOCSCTTY, 0)

    process = subprocess.Popen(
        args.command,
        stdin=slave_fd,
        stdout=slave_fd,
        stderr=slave_fd,
        close_fds=True,
        preexec_fn=make_controlling_terminal,
    )
    os.close(slave_fd)
    output = bytearray()
    scan_from = 0
    response_index = 0
    deadline = time.monotonic() + args.timeout

    def read_available(wait: float) -> bool:
        readable, _, _ = select.select([master_fd], [], [], wait)
        if not readable:
            return False
        try:
            chunk = os.read(master_fd, 65536)
        except OSError as exc:
            if exc.errno == errno.EIO:
                return False
            raise
        if not chunk:
            return False
        output.extend(chunk)
        sys.stdout.buffer.write(chunk)
        sys.stdout.buffer.flush()
        return True

    try:
        while response_index < len(responses):
            match = earliest_marker(output, scan_from)
            if match is not None:
                index, marker = match
                scan_from = index + len(marker)
                os.write(master_fd, responses[response_index].encode("utf-8") + b"\n")
                response_index += 1
                continue
            if process.poll() is not None:
                raise RuntimeError(
                    f"command exited before response {response_index + 1} of {len(responses)}"
                )
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError(
                    f"timed out waiting for prompt before response {response_index + 1}"
                )
            read_available(min(0.2, remaining))

        while process.poll() is None:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError("command did not exit after all responses were sent")
            read_available(min(0.2, remaining))
        while read_available(0.05):
            pass
    except (RuntimeError, TimeoutError) as exc:
        process.terminate()
        try:
            process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
        print(f"\nPTY driver error: {exc}", file=sys.stderr)
        return 124
    finally:
        os.close(master_fd)
        with open(args.transcript, "wb") as transcript:
            transcript.write(output)

    return process.returncode


if __name__ == "__main__":
    raise SystemExit(main())
