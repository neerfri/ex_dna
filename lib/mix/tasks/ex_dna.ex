defmodule Mix.Tasks.ExDna do
  @shortdoc "Detect code duplication in your Elixir project"
  @moduledoc """
  Scans your project for duplicated code blocks using AST analysis.

      $ mix ex_dna
      $ mix ex_dna lib/my_app/accounts
      $ mix ex_dna --min-mass 20 --literal-mode abstract
      $ mix ex_dna --min-similarity 0.85

  ## Command-line options

    * `--min-mass` — minimum AST node count (default: 30)
    * `--min-similarity` — similarity threshold 0.0–1.0 (default: 1.0).
      Values below 1.0 enable Type-III near-miss detection.
    * `--literal-mode` — `keep` (Type-I only) or `abstract` (also Type-II). Default: `keep`
    * `--normalize-pipes` — treat `x |> f()` the same as `f(x)`. Default: false
    * `--exclude-macro` — macro name to skip during analysis (repeatable).
      `@` is excluded by default. Common: `schema`, `pipe_through`, `plug`
    * `--ignore` — glob pattern to exclude (repeatable)
    * `--format` — output format: `console` (default), `json`, `html`, or `sarif`
    * `--max-clones` — maximum allowed clones. Exits with code 1 only when
      exceeded. Useful for gradual adoption in brownfield projects.

  Exits with code 1 if clones are found (or exceed `--max-clones`).
  """

  use Mix.Task

  @impl Mix.Task
  def run(argv) do
    {opts, paths, _} =
      OptionParser.parse(argv,
        strict: [
          min_mass: :integer,
          min_similarity: :float,
          literal_mode: :string,
          normalize_pipes: :boolean,
          exclude_macro: :keep,
          ignore: :keep,
          format: :string,
          max_clones: :integer
        ],
        aliases: [m: :min_mass, s: :min_similarity, i: :ignore, f: :format]
      )

    config_opts = build_config(opts, paths)
    report = ExDNA.analyze(config_opts)
    detection_ms = report.stats.detection_time_ms

    unless Keyword.get(opts, :format) in ["json", "sarif"] do
      IO.puts("  Detection time:     #{detection_ms}ms\n")
    end

    max_clones = Keyword.get(opts, :max_clones)
    total = report.stats.total_clones

    if max_clones && Keyword.get(opts, :format) not in ["json", "sarif"] do
      IO.puts("  Clone budget:       #{total}/#{max_clones}\n")
    end

    should_fail =
      if max_clones do
        total > max_clones
      else
        total > 0
      end

    if should_fail do
      System.at_exit(fn _ -> exit({:shutdown, 1}) end)
    end
  end

  defp build_config(opts, paths) do
    reporters = reporters_for(Keyword.get(opts, :format, "console"))

    literal_mode =
      case Keyword.get(opts, :literal_mode, "keep") do
        "abstract" -> :abstract
        _ -> :keep
      end

    excluded_macros =
      case Keyword.get_values(opts, :exclude_macro) do
        [] -> nil
        macros -> Enum.map(macros, &String.to_atom/1)
      end

    [
      paths: if(paths != [], do: paths, else: ["lib/"]),
      reporters: reporters,
      literal_mode: literal_mode,
      normalize_pipes: Keyword.get(opts, :normalize_pipes, false),
      ignore: Keyword.get_values(opts, :ignore)
    ]
    |> maybe_put(:min_mass, Keyword.get(opts, :min_mass))
    |> maybe_put(:min_similarity, Keyword.get(opts, :min_similarity))
    |> maybe_put(:excluded_macros, excluded_macros)
  end

  defp reporters_for("json"), do: [ExDNA.Reporter.JSON]
  defp reporters_for("html"), do: [ExDNA.Reporter.HTML]
  defp reporters_for("sarif"), do: [ExDNA.Reporter.SARIF]
  defp reporters_for(_), do: [ExDNA.Reporter.Console]

  defp maybe_put(opts, _key, nil), do: opts

  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
