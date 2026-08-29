# CalDAVTester — what is here and what is not

Vendored from https://github.com/apple/ccs-caldavtester at commit
`bed21e5924275552c1561febc8203a9f194cf737` on 2026-08-29. Apache-2.0; see LICENSE.txt.

**Upstream is archived** — it was frozen in February 2024 and will not
change again, which is why vendoring it is reasonable rather than lazy.

## What is here

* `scripts/` — 226 XML test scenarios. Each is a sequence of requests with
  the responses a conformant server must give. This is the encoded
  interop knowledge and the reason to vendor anything at all: it is
  worth reading while implementing, not only running.

* `verifiers/` — the response checks the scenarios refer to.

## What is not here

`Resource/` — about 17 MB of sample calendar and contact fixtures the
scenarios load. Omitted to keep this repository small. **The suite will
not run without them**; fetch with:

```bash
curl -sSL https://github.com/apple/ccs-caldavtester/archive/bed21e5924275552c1561febc8203a9f194cf737.tar.gz | tar xz
```

## One deliberate change from upstream

`scripts/.gitignore`, containing `/tests/`, has been deleted. It is
upstream's own build hygiene and it silently excluded 195 of the 323
vendored files — including every test scenario, which is the entire
reason for vendoring this. Nothing else has been modified.
