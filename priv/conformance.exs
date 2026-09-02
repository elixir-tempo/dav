# The conformance position, classified. Run with:
#
#     MIX_ENV=test mix run priv/conformance.exs
#
# The cheaper path is `DAV_REPORT=1 mix test`, which prints this same
# report from the run the regression test already performs. See
# `Dav.CalDAVTester.Corpus` for what the classes mean.
alias Dav.CalDAVTester.Corpus

IO.puts(Corpus.headline(Corpus.run()))
