defmodule Dav.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :dav,
      version: @version,
      name: "Dav",
      source_url: "https://github.com/elixir-tempo/dav",
      docs: docs(),
      deps: deps(),
      description: description(),
      package: package(),
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      dialyzer: [
        flags: [
          :error_handling,
          :unknown,
          :underspecs,
          :extra_return,
          :missing_return
        ]
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :xmerl]
    ]
  end

  def description do
    "WebDAV, CalDAV and CardDAV servers as a Plug — the protocol, with " <>
      "storage left to you."
  end

  def package do
    [
      maintainers: ["Kip Cole"],
      licenses: ["Apache-2.0"],
      links: links(),
      files: [
        "lib",
        "mix.exs",
        "README*",
        "CHANGELOG*",
        "LICENSE*"
      ]
    ]
  end

  def links do
    %{
      "GitHub" => "https://github.com/elixir-tempo/dav",
      "Readme" => "https://github.com/elixir-tempo/dav/blob/v#{@version}/README.md",
      "Changelog" => "https://github.com/elixir-tempo/dav/blob/v#{@version}/CHANGELOG.md"
    }
  end

  def docs do
    [
      source_ref: "v#{@version}",
      main: "readme",
      extras: ["README.md", "LICENSE.md", "CHANGELOG.md"],
      formatters: ["html", "markdown"],
      groups_for_modules: groups_for_modules(),
      skip_undefined_reference_warnings_on: ["CHANGELOG.md"]
    ]
  end

  def groups_for_modules do
    [
      Core: ~r/^Dav$/,
      "WebDAV — RFC 4918": ~r/^Dav\.Web/,
      "CalDAV — RFC 4791": ~r/^Dav\.Cal/,
      "CardDAV — RFC 6352": ~r/^Dav\.Card/,
      XML: ~r/^Dav\.Xml/
    ]
  end

  defp deps do
    [
      {:plug, "~> 1.16"},
      # Time is Tempo's. `Tempo.ICal.from_ical/2` reads calendar data
      # into intervals and `Tempo.RRule` expands recurrences, which is
      # what `time-range` filtering needs and the hardest part of
      # CalDAV to get right. iCalendar parsing arrives transitively
      # through Tempo rather than as a dependency of its own.
      {:ex_tempo, "~> 1.5"},
      # Request bodies are namespaced XML of well-known shape, which is
      # what SweetXml's extraction is good at. It rides on xmerl, and
      # `Dav.Xml` always scans with `allow_entities: false` — OTP 29
      # refuses external entities by default, but that default has
      # changed before and `allow_entities: true` demonstrably leaks
      # local files into the parsed document.
      {:sweet_xml, "~> 0.7"},
      # A time zone database, so that `TZID=America/Los_Angeles` can be
      # told from a typo. RFC 7809 lets a client name a well-known zone
      # and omit the VTIMEZONE definition, and RFC 4791 section 4.1
      # requires the definition otherwise — distinguishing the two is
      # the difference between accepting valid data and accepting
      # anything.
      {:tz, "~> 0.28"},
      # Serving and driving the server are test concerns. A library
      # that hands you a Plug should not choose your web server.
      {:bandit, "~> 1.5", only: [:dev, :test]},
      {:req, "~> 0.5", only: [:dev, :test]},
      {:ex_doc, "~> 0.38", only: [:dev, :test, :release], optional: true, runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:stream_data, "~> 1.0", only: [:dev, :test], runtime: false}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]
end
