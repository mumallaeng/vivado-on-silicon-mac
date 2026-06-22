#!/usr/bin/env python3

import argparse
import os
import pty
import selectors
import signal
import socket
import subprocess
import sys
import time


def parse_args():
    parser = argparse.ArgumentParser(
        description="Keep openFPGALoader XVC mode alive behind a pseudo-terminal."
    )
    parser.add_argument("--port", type=int, default=2542)
    parser.add_argument("--cable", default="digilent")
    parser.add_argument("--pid-file")
    parser.add_argument("--log-file")
    parser.add_argument("--vid")
    parser.add_argument("--pid")
    parser.add_argument("--cable-index")
    parser.add_argument("--ftdi-serial")
    parser.add_argument("--ftdi-channel")
    return parser.parse_args()


def append_log(log_handle, message):
    if log_handle is not None:
        log_handle.write(message)
        log_handle.flush()


def wait_for_port(port, timeout=10.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        sock = socket.socket()
        sock.settimeout(0.25)
        try:
            sock.connect(("127.0.0.1", port))
            return True
        except OSError:
            time.sleep(0.1)
        finally:
            sock.close()
    return False


def main():
    args = parse_args()

    cmd = ["openFPGALoader", "--xvc", "-c", args.cable, "--port", str(args.port)]
    if args.vid:
        cmd.extend(["--vid", args.vid])
    if args.pid:
        cmd.extend(["--pid", args.pid])
    if args.cable_index:
        cmd.extend(["--cable-index", args.cable_index])
    if args.ftdi_serial:
        cmd.extend(["--ftdi-serial", args.ftdi_serial])
    if args.ftdi_channel:
        cmd.extend(["--ftdi-channel", args.ftdi_channel])

    log_handle = None
    if args.log_file:
        log_handle = open(args.log_file, "a", encoding="utf-8", buffering=1)
        append_log(log_handle, f"\n=== openFPGALoader XVC start: {' '.join(cmd)} ===\n")

    master_fd, slave_fd = pty.openpty()
    proc = subprocess.Popen(
        cmd,
        stdin=slave_fd,
        stdout=slave_fd,
        stderr=slave_fd,
        close_fds=True,
        start_new_session=True,
    )
    os.close(slave_fd)

    if args.pid_file:
        with open(args.pid_file, "w", encoding="utf-8") as handle:
            handle.write(f"{os.getpid()}\n")

    selector = selectors.DefaultSelector()
    selector.register(master_fd, selectors.EVENT_READ)

    stopping = False
    stop_deadline = None

    def request_shutdown(*_):
        nonlocal stopping, stop_deadline
        if not stopping:
            stopping = True
            stop_deadline = time.monotonic() + 5.0
            try:
                proc.terminate()
            except ProcessLookupError:
                pass

    signal.signal(signal.SIGINT, request_shutdown)
    signal.signal(signal.SIGTERM, request_shutdown)

    if not wait_for_port(args.port):
        append_log(log_handle, f"ERROR: XVC bridge failed to open port {args.port}\n")
        request_shutdown()

    exit_code = 0
    try:
        while True:
            if proc.poll() is not None:
                exit_code = proc.returncode or 0
                break

            for key, _ in selector.select(timeout=0.5):
                try:
                    data = os.read(key.fd, 4096)
                except OSError:
                    data = b""

                if data:
                    append_log(log_handle, data.decode(errors="replace"))

            if stopping and stop_deadline is not None and time.monotonic() >= stop_deadline:
                try:
                    proc.kill()
                except ProcessLookupError:
                    pass
                stop_deadline = None
    finally:
        request_shutdown()
        try:
            proc.wait(timeout=5)
            exit_code = proc.returncode or exit_code
        except subprocess.TimeoutExpired:
            try:
                proc.kill()
            except ProcessLookupError:
                pass
            try:
                proc.wait(timeout=1)
            except subprocess.TimeoutExpired:
                pass

        try:
            selector.unregister(master_fd)
        except Exception:
            pass
        try:
            os.close(master_fd)
        except OSError:
            pass

        if args.pid_file:
            try:
                os.remove(args.pid_file)
            except FileNotFoundError:
                pass

        if log_handle is not None:
            append_log(log_handle, f"=== openFPGALoader XVC stop: exit={exit_code} ===\n")
            log_handle.close()

    return exit_code


if __name__ == "__main__":
    sys.exit(main())
