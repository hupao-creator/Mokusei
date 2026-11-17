"""Shared desktop ownership: atomic directory, never steal another owner's lock."""
import json
import os
import signal
import subprocess
import uuid

from lifecycle import Blocked
from report import save


class DesktopLease:
    def __init__(self, path, thread):
        self.path, self.identity, self.owner = path, None, None
        self.thread = thread

    def acquire(self):
        # Publish ownership before a pending deadline can enter caller cleanup.
        previous = signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGALRM, signal.SIGTERM, signal.SIGINT})
        try:
            try:
                self.path.mkdir(mode=0o700)
            except FileExistsError as error:
                raise Blocked(f"desktop lock exists: {self.path}; no lock was stolen") from error
            stat = self.path.stat()
            self.identity = (stat.st_dev, stat.st_ino)
            self.owner = {"threadId": self.thread, "pid": os.getpid(), "start": subprocess.check_output(
                ["ps", "-p", str(os.getpid()), "-o", "lstart="], text=True, timeout=5).strip(), "nonce": uuid.uuid4().hex}
            save(self.path / "owner.json", self.owner)
        finally:
            signal.pthread_sigmask(signal.SIG_SETMASK, previous)
        return {"path": str(self.path), "owner": self.owner}

    def close(self):
        if self.identity is None:
            return {"released": True, "acquired": False}
        stat = self.path.stat()
        if (stat.st_dev, stat.st_ino) != self.identity:
            raise RuntimeError("desktop lock identity changed; refusing to remove it")
        owner_file = self.path / "owner.json"
        if owner_file.exists():
            if json.loads(owner_file.read_text()) != self.owner:
                raise RuntimeError("desktop lock owner changed; refusing to remove it")
            owner_file.unlink()
        self.path.rmdir()
        self.identity = None
        return {"released": True, "acquired": True, "owner": self.owner}
