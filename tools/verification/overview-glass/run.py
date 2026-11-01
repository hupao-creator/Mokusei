"""Retired card-glass experiment launcher.

Overview cards now use fixed flat materials, so the old all-on/shell-off/all-off
matrix no longer has independent production conditions. Historical reports and
the read-only analyzer remain available; see README.md for the frozen revision.
"""

if __name__ == "__main__":
    raise SystemExit(
        "Card-glass live trials are retired. Use overview-input/run.py --card-materials "
        "for current appearance checks, or analyze.py for retained historical evidence."
    )
