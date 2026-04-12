defmodule ExDNA.AST.CharacteristicVectorTest do
  use ExUnit.Case, async: true

  alias ExDNA.AST.CharacteristicVector

  describe "compute/1" do
    test "counts node types in a simple expression" do
      ast = Code.string_to_quoted!("x + y")
      vec = CharacteristicVector.compute(ast)

      assert vec[:+] >= 1
      assert vec[:variable] >= 2
    end

    test "counts remote calls" do
      ast = Code.string_to_quoted!("Enum.map(list, fn x -> x end)")
      vec = CharacteristicVector.compute(ast)

      assert vec[:remote_call] >= 1
      assert vec[:fn] >= 1
    end

    test "similar code produces similar vectors" do
      ast_a =
        Code.string_to_quoted!("""
        data
        |> Enum.map(fn x -> x * 2 end)
        |> Enum.filter(fn x -> x > 10 end)
        |> Enum.sort()
        """)

      ast_b =
        Code.string_to_quoted!("""
        items
        |> Enum.map(fn y -> y * 3 end)
        |> Enum.filter(fn y -> y > 5 end)
        |> Enum.sort()
        """)

      vec_a = CharacteristicVector.compute(ast_a)
      vec_b = CharacteristicVector.compute(ast_b)

      sim = CharacteristicVector.cosine_similarity(vec_a, vec_b)
      assert sim > 0.9
    end

    test "different code produces different vectors" do
      ast_a = Code.string_to_quoted!("Enum.map(list, &to_string/1)")

      ast_b =
        Code.string_to_quoted!("""
        case fetch(id) do
          {:ok, result} -> process(result)
          {:error, reason} -> handle_error(reason)
        end
        """)

      vec_a = CharacteristicVector.compute(ast_a)
      vec_b = CharacteristicVector.compute(ast_b)

      sim = CharacteristicVector.cosine_similarity(vec_a, vec_b)
      assert sim < 0.8
    end
  end

  describe "cosine_similarity/2" do
    test "identical vectors return 1.0" do
      vec = %{a: 3, b: 4}
      assert_in_delta CharacteristicVector.cosine_similarity(vec, vec), 1.0, 0.001
    end

    test "orthogonal vectors return 0.0" do
      vec_a = %{a: 1}
      vec_b = %{b: 1}
      assert_in_delta CharacteristicVector.cosine_similarity(vec_a, vec_b), 0.0, 0.001
    end

    test "empty vectors return 0.0" do
      assert CharacteristicVector.cosine_similarity(%{}, %{}) == 0.0
    end
  end

  describe "LSH" do
    test "similar vectors tend to share LSH bands" do
      vec_a = %{def: 2, case: 1, pipe: 3, fn: 2, variable: 5}
      vec_b = %{def: 2, case: 1, pipe: 3, fn: 2, variable: 6}
      vec_c = %{defmodule: 5, use: 3, import: 4}

      all_keys =
        [vec_a, vec_b, vec_c]
        |> Enum.flat_map(&Map.keys/1)
        |> MapSet.new()

      hyperplanes = CharacteristicVector.generate_hyperplanes(all_keys, 64)

      sig_a = CharacteristicVector.lsh_signature(vec_a, hyperplanes)
      sig_b = CharacteristicVector.lsh_signature(vec_b, hyperplanes)
      sig_c = CharacteristicVector.lsh_signature(vec_c, hyperplanes)

      matching_ab = Enum.zip(sig_a, sig_b) |> Enum.count(fn {a, b} -> a == b end)
      matching_ac = Enum.zip(sig_a, sig_c) |> Enum.count(fn {a, b} -> a == b end)

      assert matching_ab > matching_ac
    end
  end
end
