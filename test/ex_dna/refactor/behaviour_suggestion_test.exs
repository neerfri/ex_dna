defmodule ExDNA.Refactor.BehaviourSuggestionTest do
  use ExUnit.Case, async: true

  alias ExDNA.Detection.Clone
  alias ExDNA.Refactor.BehaviourSuggestion

  setup do
    dir = Path.join(System.tmp_dir!(), "ex_dna_bs_test_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  defp def_ast(name, arity) do
    args =
      case arity do
        0 -> nil
        n -> Enum.map(1..n, fn i -> {:"arg#{i}", [line: 1], nil} end)
      end

    {:def, [line: 1], [{name, [line: 1], args}, [do: {:ok, [], nil}]]}
  end

  defp defp_ast(name, arity) do
    args =
      case arity do
        0 -> nil
        n -> Enum.map(1..n, fn i -> {:"arg#{i}", [line: 1], nil} end)
      end

    {:defp, [line: 1], [{name, [line: 1], args}, [do: {:ok, [], nil}]]}
  end

  describe "suggest/1" do
    test "suggests behaviour for identical defs in different files", %{dir: dir} do
      ast = def_ast(:validate, 1)

      file_a = Path.join(dir, "bank_complaint.ex")
      file_b = Path.join(dir, "mfo_complaint.ex")

      File.write!(file_a, """
      defmodule MyApp.BankComplaint do
        def validate(data), do: {:ok, data}
      end
      """)

      File.write!(file_b, """
      defmodule MyApp.MFOComplaint do
        def validate(data), do: {:ok, data}
      end
      """)

      clone = %Clone{
        type: :type_i,
        hash: "x",
        mass: 15,
        fragments: [
          %{file: file_a, line: 2, ast: ast, mass: 15},
          %{file: file_b, line: 2, ast: ast, mass: 15}
        ]
      }

      suggestion = BehaviourSuggestion.suggest(clone)

      assert %BehaviourSuggestion{} = suggestion
      assert suggestion.callback_name == :validate
      assert suggestion.callback_arity == 1
      assert "MyApp.BankComplaint" in suggestion.modules
      assert "MyApp.MFOComplaint" in suggestion.modules
    end

    test "suggests behaviour for zero-arity defs", %{dir: dir} do
      ast = def_ast(:defaults, 0)

      file_a = Path.join(dir, "http_client.ex")
      file_b = Path.join(dir, "grpc_client.ex")

      File.write!(file_a, "defmodule HttpClient do\n  def defaults, do: []\nend\n")
      File.write!(file_b, "defmodule GrpcClient do\n  def defaults, do: []\nend\n")

      clone = %Clone{
        type: :type_i,
        hash: "x",
        mass: 10,
        fragments: [
          %{file: file_a, line: 2, ast: ast, mass: 10},
          %{file: file_b, line: 2, ast: ast, mass: 10}
        ]
      }

      suggestion = BehaviourSuggestion.suggest(clone)
      assert suggestion.callback_name == :defaults
      assert suggestion.callback_arity == 0
    end

    test "returns nil when fragments are not defs" do
      ast =
        quote do
          Enum.map(list, fn x -> x * 2 end)
        end

      clone = %Clone{
        type: :type_i,
        hash: "x",
        mass: 10,
        fragments: [
          %{file: "lib/a.ex", line: 1, ast: ast, mass: 10},
          %{file: "lib/b.ex", line: 1, ast: ast, mass: 10}
        ]
      }

      assert BehaviourSuggestion.suggest(clone) == nil
    end

    test "returns nil when defs have different names" do
      ast_a = def_ast(:validate, 1)
      ast_b = def_ast(:verify, 1)

      clone = %Clone{
        type: :type_i,
        hash: "x",
        mass: 10,
        fragments: [
          %{file: "lib/a.ex", line: 1, ast: ast_a, mass: 10},
          %{file: "lib/b.ex", line: 1, ast: ast_b, mass: 10}
        ]
      }

      assert BehaviourSuggestion.suggest(clone) == nil
    end

    test "returns nil when all fragments come from the same file" do
      ast = def_ast(:validate, 1)

      clone = %Clone{
        type: :type_i,
        hash: "x",
        mass: 10,
        fragments: [
          %{file: "lib/complaint.ex", line: 10, ast: ast, mass: 10},
          %{file: "lib/complaint.ex", line: 30, ast: ast, mass: 10}
        ]
      }

      assert BehaviourSuggestion.suggest(clone) == nil
    end

    test "returns nil for fewer than 2 fragments" do
      ast = def_ast(:validate, 1)

      clone = %Clone{
        type: :type_i,
        hash: "x",
        mass: 10,
        fragments: [%{file: "lib/a.ex", line: 1, ast: ast, mass: 10}]
      }

      assert BehaviourSuggestion.suggest(clone) == nil
    end

    test "works with defp as well as def", %{dir: dir} do
      ast = defp_ast(:transform, 1)

      file_a = Path.join(dir, "parser_a.ex")
      file_b = Path.join(dir, "parser_b.ex")

      File.write!(file_a, "defmodule ParserA do\n  defp transform(x), do: x\nend\n")
      File.write!(file_b, "defmodule ParserB do\n  defp transform(x), do: x\nend\n")

      clone = %Clone{
        type: :type_i,
        hash: "x",
        mass: 8,
        fragments: [
          %{file: file_a, line: 2, ast: ast, mass: 8},
          %{file: file_b, line: 2, ast: ast, mass: 8}
        ]
      }

      suggestion = BehaviourSuggestion.suggest(clone)
      assert suggestion.callback_name == :transform
      assert suggestion.callback_arity == 1
    end

    test "preserves acronyms in module names", %{dir: dir} do
      ast = def_ast(:run, 0)

      file_a = Path.join(dir, "http_api.ex")
      file_b = Path.join(dir, "grpc_api.ex")

      File.write!(file_a, "defmodule MyApp.HTTPAPI do\n  def run, do: :ok\nend\n")
      File.write!(file_b, "defmodule MyApp.GRPCAPI do\n  def run, do: :ok\nend\n")

      clone = %Clone{
        type: :type_i,
        hash: "x",
        mass: 8,
        fragments: [
          %{file: file_a, line: 2, ast: ast, mass: 8},
          %{file: file_b, line: 2, ast: ast, mass: 8}
        ]
      }

      suggestion = BehaviourSuggestion.suggest(clone)
      assert "MyApp.HTTPAPI" in suggestion.modules
      assert "MyApp.GRPCAPI" in suggestion.modules
    end
  end

  describe "analyze/1" do
    test "attaches behaviour_suggestion to qualifying clones", %{dir: dir} do
      ast = def_ast(:validate, 1)

      file_a = Path.join(dir, "bank.ex")
      file_b = Path.join(dir, "mfo.ex")

      File.write!(file_a, "defmodule Bank do\n  def validate(d), do: d\nend\n")
      File.write!(file_b, "defmodule MFO do\n  def validate(d), do: d\nend\n")

      clones = [
        %Clone{
          type: :type_i,
          hash: "x",
          mass: 10,
          fragments: [
            %{file: file_a, line: 2, ast: ast, mass: 10},
            %{file: file_b, line: 2, ast: ast, mass: 10}
          ]
        }
      ]

      [clone] = BehaviourSuggestion.analyze(clones)
      assert %BehaviourSuggestion{} = clone.behaviour_suggestion
      assert clone.behaviour_suggestion.callback_name == :validate
    end

    test "leaves behaviour_suggestion nil for non-qualifying clones" do
      ast =
        quote do
          Enum.map(list, fn x -> x * 2 end)
        end

      clones = [
        %Clone{
          type: :type_i,
          hash: "x",
          mass: 10,
          fragments: [
            %{file: "lib/a.ex", line: 1, ast: ast, mass: 10},
            %{file: "lib/b.ex", line: 1, ast: ast, mass: 10}
          ]
        }
      ]

      [clone] = BehaviourSuggestion.analyze(clones)
      assert clone.behaviour_suggestion == nil
    end
  end
end
