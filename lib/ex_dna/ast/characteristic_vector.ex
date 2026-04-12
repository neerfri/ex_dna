defmodule ExDNA.AST.CharacteristicVector do
  @moduledoc """
  Computes characteristic vectors for AST subtrees (DECKARD-style).

  A characteristic vector is a map of `%{node_type => count}` that captures
  the structural composition of a subtree. Two subtrees with similar vectors
  are likely similar code, enabling fast candidate pruning for Type-III
  clone detection without expensive pairwise tree comparison.

  The cosine similarity between two vectors approximates structural similarity
  much more cheaply than full tree edit distance.
  """

  @doc """
  Compute the characteristic vector for an AST node.

  Returns a map where keys are node type atoms and values are occurrence counts.
  """
  @spec compute(Macro.t()) :: %{atom() => pos_integer()}
  def compute(ast), do: walk(ast, %{})

  defp walk({form, _meta, args}, vec) when is_atom(form) and is_list(args) do
    vec
    |> Map.update(form, 1, &(&1 + 1))
    |> then(&Enum.reduce(args, &1, fn child, v -> walk(child, v) end))
  end

  defp walk({{:., _dot_meta, call_parts}, _meta, args}, vec) do
    vec = Map.update(vec, :remote_call, 1, &(&1 + 1))

    vec =
      case call_parts do
        [{:__aliases__, _, parts}, func] when is_atom(func) and is_list(parts) ->
          if Enum.all?(parts, &is_atom/1) do
            key = :"#{Enum.join(parts, ".")}.#{func}"
            Map.update(vec, key, 1, &(&1 + 1))
          else
            vec
          end

        _ ->
          vec
      end

    vec = Enum.reduce(call_parts, vec, fn part, v -> walk(part, v) end)
    Enum.reduce(args, vec, fn child, v -> walk(child, v) end)
  end

  defp walk({_form, _meta, context}, vec) when is_atom(context) do
    Map.update(vec, :variable, 1, &(&1 + 1))
  end

  defp walk({key, value}, vec) when is_atom(key) do
    walk(value, vec)
  end

  defp walk({left, right}, vec) do
    walk(right, walk(left, vec))
  end

  defp walk(list, vec) when is_list(list) do
    Enum.reduce(list, vec, fn item, v -> walk(item, v) end)
  end

  defp walk(val, vec) when is_integer(val), do: Map.update(vec, :integer, 1, &(&1 + 1))
  defp walk(val, vec) when is_float(val), do: Map.update(vec, :float, 1, &(&1 + 1))
  defp walk(val, vec) when is_binary(val), do: Map.update(vec, :string, 1, &(&1 + 1))
  defp walk(val, vec) when is_atom(val), do: Map.update(vec, :atom, 1, &(&1 + 1))
  defp walk(_other, vec), do: vec

  @doc """
  Compute cosine similarity between two characteristic vectors.

  Returns a float between 0.0 (completely different) and 1.0 (identical distribution).
  """
  @spec cosine_similarity(%{atom() => number()}, %{atom() => number()}) :: float()
  def cosine_similarity(vec_a, vec_b) do
    keys = MapSet.union(MapSet.new(Map.keys(vec_a)), MapSet.new(Map.keys(vec_b)))

    {dot, norm_a_sq, norm_b_sq} =
      Enum.reduce(keys, {0.0, 0.0, 0.0}, fn key, {dot, na, nb} ->
        a = Map.get(vec_a, key, 0)
        b = Map.get(vec_b, key, 0)
        {dot + a * b, na + a * a, nb + b * b}
      end)

    denom = :math.sqrt(norm_a_sq) * :math.sqrt(norm_b_sq)

    if denom == 0.0, do: 0.0, else: dot / denom
  end

  @doc """
  Compute random hyperplane LSH signatures for a characteristic vector.

  Each bit indicates which side of a random hyperplane the vector falls on.
  Two vectors with matching signature bits in a band are likely similar.
  """
  @spec lsh_signature(%{atom() => number()}, [[{atom(), float()}]]) :: [boolean()]
  def lsh_signature(vec, hyperplanes) do
    Enum.map(hyperplanes, fn plane ->
      dot = Enum.reduce(plane, 0.0, fn {key, val}, acc -> acc + Map.get(vec, key, 0) * val end)
      dot >= 0
    end)
  end

  @doc """
  Generate random hyperplanes for LSH.

  Each hyperplane is a list of `{dimension_key, random_value}` pairs.
  Generate once and reuse across all fragments in a detection run.
  """
  @spec generate_hyperplanes(MapSet.t(atom()), pos_integer()) :: [[{atom(), float()}]]
  def generate_hyperplanes(all_keys, num_hashes) do
    keys_list = MapSet.to_list(all_keys)

    for _i <- 1..num_hashes do
      Enum.map(keys_list, fn key -> {key, :rand.normal()} end)
    end
  end
end
