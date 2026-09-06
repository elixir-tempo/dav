#!/usr/bin/env python3
"""Build a runnable CalDAVTester from the vendored, unmodified upstream.

    python3 priv/caldavtester.py [--out DIR] [--no-pycalendar]

Apple's harness is Python 2 and archived, frozen in February 2024. It
will not be ported upstream and there is nothing to track, so the
vendored copy under `rfc/conformance/caldavtester/` is kept
byte-identical to the pinned commit and the port happens here instead.

That is the point of this script: `git diff` against upstream stays
empty, the transformation is reviewable as code rather than as a
110-line patch, and re-running it after a re-fetch costs nothing.

What it produces is a tree you can run against the endpoint that
`priv/serve.exs` serves:

    MIX_ENV=test mix run --no-halt priv/serve.exs 8008    # in one shell
    python3 priv/caldavtester.py                          # in another
    cd _build/caldavtester/caldavtester
    PYTHONPATH=../pycalendar:src python3 testcaldav.py \
        -s scripts/server/serverinfo.xml CalDAV/propfind.xml

`pycalendar` is Apple's iCalendar library, which five of the verifiers
import. It is a separate archived repository, needs the same
treatment, and is cloned rather than vendored — hence the network.
Pass `--no-pycalendar` to skip it when it is already in place.
"""

import argparse
import pathlib
import re
import shutil
import subprocess
import sys

UPSTREAM = "https://github.com/apple/ccs-pycalendar.git"


def two_to_three(root):
    """The mechanical half: print statements, `except X, e`, relative imports."""
    subprocess.run(
        [sys.executable, "-m", "lib2to3", "-w", "-n", str(root)],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )


def edit(path, replacements, regex=False):
    text = path.read_text()

    for before, after in replacements:
        # Multiline, so `^`/`$` anchor to lines — several of the
        # replacements below match whole import statements.
        text = re.sub(before, after, text, flags=re.M) if regex else text.replace(before, after)

    path.write_text(text)


def port_harness(root):
    """The parts `2to3` does not know about."""
    for path in root.rglob("*.py"):
        edit(
            path,
            [
                # ElementTree dropped getchildren() in 3.9. Iterating the
                # element is the documented replacement.
                (r"([A-Za-z_][A-Za-z0-9_.\[\]()]*)\.getchildren\(\)", r"list(\1)"),
                # Python 2 encoded text to get its `str`. On 3 the parser
                # already hands back `str`, so these invert the meaning.
                (r"\.text\.(?:en|de)code\(\s*[\"']utf-8[\"']\s*\)", ".text"),
            ],
            regex=True,
        )

    edit(
        root / "src" / "request.py",
        [
            (r"\.encode\(\s*[\"']utf-8[\"']\s*\)", ""),
            # Renamed in Python 3, and the argument and result are bytes.
            (
                r'base64\.encodestring\(basicauth\)',
                'base64.encodebytes(basicauth.encode("utf-8")).decode("ascii")',
            ),
        ],
        regex=True,
    )

    edit(
        root / "src" / "caldavtest.py",
        [
            (r"\.encode\(\s*[\"']utf-8[\"']\s*\)", ""),
            # `rfc822` went in Python 3; `email.utils.parsedate` is the
            # same function under a new roof.
            (r"^import rfc822$", "import email.utils"),
            (r"rfc822\.parsedate\(", "email.utils.parsedate("),
        ],
        regex=True,
    )

    # Two places where py3 hands back bytes and everything downstream is
    # written for text: the raw request the harness records for its own
    # logs, and the response body every verifier reads.
    edit(
        root / "src" / "caldavtest.py",
        [
            (
                "    self.requestData += str\n",
                '    self.requestData += str.decode("utf-8", "replace") '
                "if isinstance(str, bytes) else str\n",
            ),
            (
                "            respdata = response.read()\n",
                "            respdata = response.read()\n"
                "            if isinstance(respdata, bytes):\n"
                '                respdata = respdata.decode("utf-8", "replace")\n',
            ),
        ],
    )


def port_pycalendar(out):
    """Apple's iCalendar library, which the verifiers import."""
    clone = out / "ccs-pycalendar"

    if not clone.exists():
        subprocess.run(
            ["git", "clone", "--quiet", "--depth", "1", UPSTREAM, str(clone)], check=True
        )

    target = out / "pycalendar" / "pycalendar"
    shutil.rmtree(target.parent, ignore_errors=True)
    target.parent.mkdir(parents=True)
    shutil.copytree(clone / "src" / "pycalendar", target)

    two_to_three(target)

    # `2to3` rewrites `import icalendar.recurrencevalue` to
    # `from . import icalendar.recurrencevalue`, which is not valid
    # syntax. The intent is the submodule.
    edit(
        target / "__init__.py",
        [(r"^from \. import ([a-z_]+)\.([a-z_]+)$", r"from .\1 import \2")],
        regex=True,
    )


def main():
    here = pathlib.Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", default=str(here / "_build" / "caldavtester"))
    parser.add_argument("--no-pycalendar", action="store_true")
    arguments = parser.parse_args()

    out = pathlib.Path(arguments.out)
    harness = out / "caldavtester"

    shutil.rmtree(harness, ignore_errors=True)
    harness.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(
        here / "rfc" / "conformance" / "caldavtester",
        harness,
        ignore=shutil.ignore_patterns("__pycache__"),
    )

    two_to_three(harness)
    port_harness(harness)

    if not arguments.no_pycalendar:
        port_pycalendar(out)

    unparsed = [
        path
        for path in harness.rglob("*.py")
        if subprocess.run(
            [sys.executable, "-m", "py_compile", str(path)],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        ).returncode
    ]

    if unparsed:
        print("still not valid Python 3:", *[str(p) for p in unparsed], sep="\n  ")
        return 1

    print(f"CalDAVTester built in {harness}")
    print(f"  cd {harness}")
    print("  PYTHONPATH=../pycalendar:src python3 testcaldav.py \\")
    print("      -s scripts/server/serverinfo.xml CalDAV/propfind.xml")

    return 0


if __name__ == "__main__":
    sys.exit(main())
