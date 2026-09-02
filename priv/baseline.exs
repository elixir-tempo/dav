# Regenerates `test/support/caldavtester/baseline.exs` on its own. The
# cheaper path is `DAV_BASELINE=1 mix test`, which takes the same
# measurement and runs the gates with it rather than running the corpus
# a second time.
alias Dav.CalDAVTester.Corpus

start = System.monotonic_time(:millisecond)
counts = Corpus.record(Corpus.run())
elapsed = System.monotonic_time(:millisecond) - start

IO.puts(
  "#{map_size(counts)} scenarios, #{Enum.sum(Map.values(counts))} passing tests, #{elapsed}ms"
)
