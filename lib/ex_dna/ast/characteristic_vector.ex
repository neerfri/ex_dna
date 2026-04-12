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
  def compute(ast) do
    {_ast, vector} = walk(ast, %{})
    vector
  end

  defp walk({form, _meta, args} = _node, vec) when is_atom(form) and is_list(args) do
    vec = Map.update(vec, form, 1, &(&1 + 1))
    {nil, Enum.reduce(args, vec, fn child, v -> elem(walk(child, v), 1) end)}
  end

  defp walk({{:., _dot_meta, call_parts}, _meta, args}, vec) do
    vec = Map.update(vec, :remote_call, 1, &(&1 + 1))

    vec =
      case call_parts do
        [{:__aliases__, _, parts}, func] when is_atom(func) ->
          key = :"#{Enum.join(parts, ".")}.#{func}"
          Map.update(vec, key, 1, &(&1 + 1))

        _ ->
          vec
      end

    vec = Enum.reduce(call_parts, vec, fn part, v -> elem(walk(part, v), 1) end)
    {nil, Enum.reduce(args, vec, fn child, v -> elem(walk(child, v), 1) end)}
  end

  defp walk({form, _meta, context}, vec) when is_atom(form) and is_atom(context) do
    {nil, Map.update(vec, :variable, 1, &(&1 + 1))}
  end

  defp walk({left, right}, vec) do
    {_, vec} = walk(left, vec)
    {nil, elem(walk(right, vec), 1)}
  end

  defp walk(list, vec) when is_list(list) do
    {nil, Enum.reduce(list, vec, fn item, v -> elem(walk(item, v), 1) end)}
  end

  defp walk(val, vec) when is_integer(val),
    do: {nil, Map.update(vec, :integer, 1, &(&1 + 1))}

  defp walk(val, vec) when is_float(val),
    do: {nil, Map.update(vec, :float, 1, &(&1 + 1))}

  defp walk(val, vec) when is_binary(val),
    do: {nil, Map.update(vec, :string, 1, &(&1 + 1))}

  defp walk(val, vec) when is_atom(val),
    do: {nil, Map.update(vec, :atom, 1, &(&1 + 1))}

  defp walk(_other, vec), do: {nil, vec}

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

    norm_a = :math.sqrt(norm_a_sq)
    norm_b = :math.sqrt(norm_b_sq)

    if norm_a == 0.0 or norm_b == 0.0 do
      0.0
    else
      dot / (norm_a * norm_b)
    end
  end

  @doc """
  Compute random hyperplane LSH signatures for a characteristic vector.

  Returns a bitstring of `num_hashes` bits. Two vectors with the same
  signature bits in a band are likely similar (cosine similarity).

  The `hyperplanes` argument is a list of `%{atom => float}` maps
  representing random unit vectors. Generate once and reuse across all fragments.
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
  Only dimensions that appear in the given set of keys are included.
  """
  @spec generate_hyperplanes(MapSet.t(atom()), pos_integer()) :: [[{atom(), float()}]]
  def generate_hyperplanes(all_keys, num_hashes) do
    keys_list = MapSet.to_list(all_keys)

    for _i <- 1..num_hashes do
      Enum.map(keys_list, fn key -> {key, :rand.normal()} end)
    end
  end
end
