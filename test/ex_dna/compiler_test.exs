defmodule ExDNA.CompilerTest do
  use ExUnit.Case, async: false

  alias ExDNA.{Cache, Config}
  alias ExDNA.Detection.{Detector, Pipeline}

  setup do
    dir =
      Path.join(System.tmp_dir!(), "ex_dna_compiler_test_#{:erlang.unique_integer([:positive])}")

    File.mkdir_p!(dir)

    cache_path = Path.join(dir, ".ex_dna_cache")

    on_exit(fn -> File.rm_rf!(dir) end)

    {:ok, dir: dir, cache_path: cache_path}
  end

  describe "incremental pipeline with cache" do
    test "cached ASTs enable full Type-I/II/III detection", %{dir: dir, cache_path: cache_path} do
      write_duplicate_files(dir)

      config = Config.new(paths: [dir], reporters: [], min_mass: 5)
      files = Pipeline.collect_files(config)

      fresh_entries =
        Map.new(files, fn file ->
          with {:ok, source} <- File.read(file),
               {:ok, ast} <- Pipeline.parse_with_timeout(source, file, config.parse_timeout) do
            frags = Pipeline.fingerprint_ast(ast, file, config)
            {file, Cache.build_entry(file, frags, ast)}
          end
        end)

      Cache.write(fresh_entries, cache_path)

      cached = Cache.read(cache_path)

      file_ast_pairs =
        Enum.flat_map(cached, fn {file, entry} ->
          case entry do
            %{ast: ast} when ast != nil -> [{file, ast}]
            _ -> []
          end
        end)

      {clones, _} = Detector.run(config, file_ast_pairs)
      assert clones != []
    end

    test "cache entries include ASTs", %{dir: dir} do
      file = Path.join(dir, "test.ex")

      File.write!(file, """
      defmodule Test do
        def foo(x), do: x + 1
      end
      """)

      config = Config.new(paths: [dir], reporters: [], min_mass: 5)

      {:ok, source} = File.read(file)
      {:ok, ast} = Pipeline.parse_with_timeout(source, file, config.parse_timeout)
      frags = Pipeline.fingerprint_ast(ast, file, config)

      entry = Cache.build_entry(file, frags, ast)
      assert entry.ast != nil
      assert is_tuple(entry.ast)
    end
  end

  defp write_duplicate_files(dir) do
    for name <- ~w(dup_a.ex dup_b.ex) do
      File.write!(Path.join(dir, name), """
      defmodule #{String.replace(name, ".ex", "") |> Macro.camelize()} do
        def process(data) do
          data
          |> Enum.map(fn x -> x * 2 end)
          |> Enum.filter(fn x -> x > 10 end)
          |> Enum.sort()
          |> Enum.take(5)
        end
      end
      """)
    end
  end
end
