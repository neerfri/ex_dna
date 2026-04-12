defmodule ExDNA.Detection.Fuzzy do
  @moduledoc """
  Type-III (near-miss) clone detection using sub-hash Jaccard similarity.

  Each candidate fragment is characterized by its set of sub-subtree hashes
  (all hashes from children that were fingerprinted). Jaccard similarity
  between hash sets is a cheap, effective pre-filter that correlates well
  with actual tree edit distance — unlike cosine similarity on node-type
  frequencies which is too coarse for Elixir ASTs.

  Fragments are grouped by mass range to limit comparisons, then pairs
  passing the Jaccard pre-filter are verified with tree edit distance.
  """

  alias ExDNA.AST.{EditDistance, Fingerprint, Normalizer}
  alias ExDNA.Detection.Clone

  @mass_tolerance 0.3
  @jaccard_threshold 0.3
  @sub_hash_min_mass 5

  @doc """
  Find Type-III clones from a list of fragments at the given similarity threshold.
  """
  @spec detect([map()], float(), MapSet.t()) :: [Clone.t()]
  def detect(fragments, min_similarity, exact_hashes) do
    fragments
    |> Enum.reject(fn f -> MapSet.member?(exact_hashes, f.hash) end)
    |> Enum.sort_by(& &1.mass, :desc)
    |> attach_sub_hashes()
    |> group_by_mass_bucket()
    |> Enum.flat_map(fn bucket -> find_pairs_in_bucket(bucket, min_similarity) end)
    |> deduplicate_pairs()
    |> Enum.map(&pair_to_clone/1)
  end

  defp attach_sub_hashes(fragments) do
    Enum.map(fragments, fn frag ->
      sub_hashes = collect_sub_hashes(frag.ast) |> MapSet.new()
      Map.put(frag, :sub_hashes, sub_hashes)
    end)
  end

  defp collect_sub_hashes(ast) do
    {_ast, hashes} = do_collect(ast, [])
    hashes
  end

  defp do_collect({form, _meta, args} = node, acc) when is_atom(form) and is_list(args) do
    acc = Enum.reduce(args, acc, fn child, a -> elem(do_collect(child, a), 1) end)

    if Fingerprint.mass(node) >= @sub_hash_min_mass do
      stripped = Normalizer.strip_metadata(node)
      hash = :erlang.phash2(stripped)
      {node, [hash | acc]}
    else
      {node, acc}
    end
  end

  defp do_collect({left, right}, acc) do
    {_, acc} = do_collect(left, acc)
    {nil, elem(do_collect(right, acc), 1)}
  end

  defp do_collect(list, acc) when is_list(list) do
    {nil, Enum.reduce(list, acc, fn item, a -> elem(do_collect(item, a), 1) end)}
  end

  defp do_collect(leaf, acc), do: {leaf, acc}

  defp group_by_mass_bucket(fragments) do
    fragments
    |> Enum.chunk_by(fn f -> div(f.mass, 10) end)
    |> merge_adjacent_buckets()
  end

  defp merge_adjacent_buckets([]), do: []
  defp merge_adjacent_buckets([only]), do: [only]

  defp merge_adjacent_buckets([bucket_a, bucket_b | rest]) do
    merged = bucket_a ++ bucket_b
    [merged | merge_adjacent_buckets([bucket_b | rest])]
  end

  defp find_pairs_in_bucket(bucket, min_similarity) do
    indexed = Enum.with_index(bucket)

    # Pre-normalize all ASTs once
    norms = Map.new(indexed, fn {frag, idx} -> {idx, Normalizer.normalize(frag.ast)} end)

    for {frag_a, i} <- indexed,
        {frag_b, j} <- indexed,
        j > i,
        mass_compatible?(frag_a, frag_b),
        not same_location?(frag_a, frag_b),
        jaccard_compatible?(frag_a, frag_b),
        sim = EditDistance.similarity(norms[i], norms[j]),
        sim >= min_similarity do
      {frag_a, frag_b, sim}
    end
  end

  defp jaccard_compatible?(a, b) do
    intersection = MapSet.intersection(a.sub_hashes, b.sub_hashes) |> MapSet.size()
    union = MapSet.union(a.sub_hashes, b.sub_hashes) |> MapSet.size()

    if union == 0, do: false, else: intersection / union >= @jaccard_threshold
  end

  defp mass_compatible?(a, b) do
    ratio = min(a.mass, b.mass) / max(a.mass, b.mass)
    ratio >= 1.0 - @mass_tolerance
  end

  defp same_location?(a, b) do
    a.file == b.file and a.line == b.line
  end

  defp deduplicate_pairs(pairs) do
    pairs
    |> Enum.sort_by(fn {_, _, sim} -> sim end, :desc)
    |> Enum.reduce({[], MapSet.new()}, fn {a, b, sim}, {acc, seen} ->
      key_a = {a.file, a.line}
      key_b = {b.file, b.line}

      if MapSet.member?(seen, key_a) or MapSet.member?(seen, key_b) do
        {acc, seen}
      else
        seen = seen |> MapSet.put(key_a) |> MapSet.put(key_b)
        {[{a, b, sim} | acc], seen}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp pair_to_clone({frag_a, frag_b, similarity}) do
    mass = max(frag_a.mass, frag_b.mass)

    %Clone{
      type: :type_iii,
      hash: nil,
      mass: mass,
      fragments: [
        %{file: frag_a.file, line: frag_a.line, ast: frag_a.ast, mass: frag_a.mass},
        %{file: frag_b.file, line: frag_b.line, ast: frag_b.ast, mass: frag_b.mass}
      ],
      suggestion: nil,
      similarity: similarity
    }
  end
end
