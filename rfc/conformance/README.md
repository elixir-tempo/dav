# Conformance testing

Two suites matter for this family, and only one of them is vendored.

## CalDAVTester — vendored

Apple's CalDAV and CardDAV conformance suite, in `caldavtester/`. See
`caldavtester/FETCHING.md` for the pinned commit and for the fixture
directory that was deliberately left out.

It is worth having locally even before there is anything to run it
against: each of the 226 scenarios is a sequence of requests with the
responses a conformant server must return, which makes the suite a
better specification of client expectations than the RFCs are. Where
the RFC says what is permitted, these say what Apple Calendar will
actually do.

## litmus — not vendored, and deliberately

The standard WebDAV conformance suite, from
https://github.com/notroj/litmus — actively maintained, unlike
CalDAVTester.

Not vendored for two reasons. It is a C program you build and run
against a server rather than data you read, so a copy here would rot
without being useful. And it is GPL-2.0, which is a licence this
project does not otherwise carry; keeping it out avoids muddying the
licensing of a repository that ships under a permissive one.

Obtain and run it when there is a server to point it at:

```bash
git clone https://github.com/notroj/litmus && cd litmus
./configure && make
make URL=http://localhost:4000/dav/ check
```

It covers the base protocol — `PROPFIND`, properties, `COPY`/`MOVE`,
locking where advertised — and it is the fastest way to find out
whether a WebDAV implementation is honest about what it claims in
its `DAV:` response header.

## What neither of them covers

Neither exercises the free/busy path that would make a CalDAV server
worth building here — `free-busy-query` answered from derived
availability. That would need tests written against
[the Dav plan](../../plans/dav.md)'s tier 2, and they do not
exist anywhere to be borrowed.
