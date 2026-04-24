defmodule ExDNA.AST.FingerprintTest do
  use ExUnit.Case, async: true

  alias ExDNA.AST.Fingerprint

  describe "fragments/4" do
    test "excludes ignored attributes (moduledoc, type, spec, etc.)" do
      ast =
        quote do
          defmodule Foo do
            @moduledoc "Some docs"
            @type t :: %{name: String.t()}

            def process(data) do
              data
              |> Enum.map(fn x -> x * 2 end)
              |> Enum.filter(fn x -> x > 10 end)
            end
          end
        end

      ignored = [:moduledoc, :type, :typep, :spec, :doc, :callback, :impl]
      frags = Fingerprint.fragments(ast, "test.ex", 3, ignored_attributes: ignored)

      attr_frags =
        Enum.filter(frags, fn f -> match?({:@, _, _}, f.ast) end)

      assert attr_frags == []

      has_process =
        Enum.any?(frags, fn f ->
          Macro.to_string(f.ast) |> String.contains?("process")
        end)

      assert has_process
    end

    test "fingerprints non-ignored module attributes" do
      ast =
        quote do
          defmodule Foo do
            @extensions [".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs", ".json"]

            def process(data), do: data
          end
        end

      ignored = [:moduledoc, :type, :spec, :doc]
      frags = Fingerprint.fragments(ast, "test.ex", 3, ignored_attributes: ignored)

      attr_frags =
        Enum.filter(frags, fn f -> match?({:@, _, _}, f.ast) end)

      assert length(attr_frags) == 1
      [{:@, _, [{:extensions, _, _}]}] = Enum.map(attr_frags, & &1.ast)
    end

    test "excludes specified macros" do
      ast =
        quote do
          defmodule MySchema do
            use Ecto.Schema

            schema "users" do
              field(:name, :string)
              field(:email, :string)
            end

            def changeset(user, attrs) do
              user
              |> Ecto.Changeset.cast(attrs, [:name, :email])
              |> Ecto.Changeset.validate_required([:name])
            end
          end
        end

      frags_without = Fingerprint.fragments(ast, "test.ex", 3, excluded_macros: [])

      frags_with =
        Fingerprint.fragments(ast, "test.ex", 3, excluded_macros: [:schema, :field])

      schema_frags_without =
        Enum.filter(frags_without, fn f ->
          Macro.to_string(f.ast) |> String.contains?("schema")
        end)

      schema_frags_with =
        Enum.filter(frags_with, fn f ->
          match?({:schema, _, _}, f.ast) or match?({:field, _, _}, f.ast)
        end)

      assert length(schema_frags_without) > length(schema_frags_with)
    end

    test "ignored attributes don't prevent child fragments from non-excluded code" do
      ast =
        quote do
          defmodule Foo do
            @moduledoc "docs"

            def process(data) do
              data
              |> Enum.map(fn x -> x * 2 end)
            end
          end
        end

      frags = Fingerprint.fragments(ast, "test.ex", 3, ignored_attributes: [:moduledoc])

      has_process =
        Enum.any?(frags, fn f ->
          Macro.to_string(f.ast) |> String.contains?("process")
        end)

      assert has_process
    end

    test "sibling window fragments are synthetic __block__ nodes" do
      ast =
        quote do
          defmodule Foo do
            def process(x) do
              x |> Enum.map(fn i -> i.name end) |> Enum.reject(&is_nil/1)
            end

            def transform(y) do
              y |> Enum.map(fn i -> i.age end) |> Enum.filter(fn i -> i > 0 end)
            end
          end
        end

      frags = Fingerprint.fragments(ast, "test.ex", 3)

      block_frags =
        Enum.filter(frags, fn f -> match?({:__block__, _, _}, f.ast) end)

      for frag <- block_frags do
        {:__block__, [], children} = frag.ast
        assert length(children) >= 2
      end
    end
  end

  describe "mass/1" do
    test "counts leaf as 1" do
      assert Fingerprint.mass(42) == 1
      assert Fingerprint.mass(:ok) == 1
    end

    test "counts call nodes" do
      # foo(1, 2) → {:foo, [], [1, 2]} = 1 call + 2 args = 3
      ast = quote do: foo(1, 2)
      assert Fingerprint.mass(ast) == 3
    end

    test "counts nested structures" do
      # foo(bar(1), 2) → 1 (foo) + 1 (bar) + 1 (1) + 1 (2) = 4
      ast = quote do: foo(bar(1), 2)
      assert Fingerprint.mass(ast) == 4
    end
  end

  describe "excluded macros in sibling windows" do
    test "use/import blocks are excluded from sibling windows" do
      code_a = """
      defmodule A do
        use Phoenix.Component
        import Phoenix.HTML, only: [raw: 1]
        import SomeApp.ContentHelpers, only: [body_to_html: 1]
        import SomeApp.CoreComponents, only: [icon: 1]

        def render(assigns), do: assigns
      end
      """

      code_b = """
      defmodule B do
        use Phoenix.Component
        import Phoenix.HTML, only: [raw: 1]
        import SomeApp.ContentHelpers, only: [body_to_html: 1]
        import SomeApp.CoreComponents, only: [icon: 1]

        def render(assigns), do: assigns
      end
      """

      ast_a = Code.string_to_quoted!(code_a)
      ast_b = Code.string_to_quoted!(code_b)

      excluded = [:use, :import]

      frags_a = Fingerprint.fragments(ast_a, "a.ex", 20, excluded_macros: excluded)
      frags_b = Fingerprint.fragments(ast_b, "b.ex", 20, excluded_macros: excluded)

      window_frags_a = Enum.filter(frags_a, &match?({:__block__, _, _}, &1.ast))
      window_frags_b = Enum.filter(frags_b, &match?({:__block__, _, _}, &1.ast))

      hashes_a = MapSet.new(window_frags_a, & &1.hash)
      hashes_b = MapSet.new(window_frags_b, & &1.hash)

      shared = MapSet.intersection(hashes_a, hashes_b)
      assert MapSet.size(shared) == 0
    end
  end

  describe "sibling window fingerprinting" do
    test "detects identical consecutive statement sequences across files" do
      code_a = """
      defmodule A do
        def extra(x), do: x

        def setup(conn) do
          conn |> assign(:user, nil)
        end

        def process(data) do
          data |> Enum.map(& &1.name) |> Enum.sort()
        end
      end
      """

      code_b = """
      defmodule B do
        def setup(conn) do
          conn |> assign(:user, nil)
        end

        def process(data) do
          data |> Enum.map(& &1.name) |> Enum.sort()
        end

        def other(x), do: x * 2
      end
      """

      ast_a = Code.string_to_quoted!(code_a)
      ast_b = Code.string_to_quoted!(code_b)

      frags_a = Fingerprint.fragments(ast_a, "a.ex", 5)
      frags_b = Fingerprint.fragments(ast_b, "b.ex", 5)

      window_frags_a =
        Enum.filter(frags_a, fn f -> match?({:__block__, _, _}, f.ast) end)

      window_frags_b =
        Enum.filter(frags_b, fn f -> match?({:__block__, _, _}, f.ast) end)

      hashes_a = MapSet.new(window_frags_a, & &1.hash)
      hashes_b = MapSet.new(window_frags_b, & &1.hash)

      shared = MapSet.intersection(hashes_a, hashes_b)
      assert MapSet.size(shared) > 0
    end
  end
end
