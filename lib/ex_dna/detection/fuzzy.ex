defmodule ExDNA.Detection.Fuzzy do
  @moduledoc """
  Type-III (near-miss) clone detection using sub-hash Jaccard similarity.

  Each fragment carries a set of lightweight sub-hashes from its child
  subtrees (computed during fingerprinting). An inverted index on sub-hashes
  generates candidate pairs without O(n²) pairwise iteration — only fragments
  sharing at least one structural sub-hash are compared. Jaccard similarity
  on the full sub-hash sets then pre-filters before tree edit distance.
  """

  alias ExDNA.AST.{EditDistance, Normalizer}
  alias ExDNA.Detection.Clone

  # Only compare fragments within ±30% mass of each other
  @mass_tolerance 0.3
  # Minimum Jaccard overlap to proceed to expensive edit distance.
  # 0.3 balances recall (lower catches more) vs precision (higher = fewer false positives).
  # Empirically tuned on Phoenix, Ecto, Livebook, Ash, Plausible.
  @jaccard_threshold 0.3
  # Skip sub-hashes shared by 100+ fragments — these are structural noise
  # (e.g. common def/fn patterns) that would generate too many candidate pairs.
  # Fragments exceeding this are sampled (largest mass first) rather than dropped.
  @max_posting_list 100

  @doc """
  Find Type-III clones from a list of fragments at the given similarity threshold.
  """
  @spec detect([map()], float(), MapSet.t()) :: [Clone.t()]
  def detect(fragments, min_similarity, exact_hashes) do
    candidates =
      fragments
      |> Enum.reject(fn f -> MapSet.member?(exact_hashes, f.hash) end)
      |> Enum.sort_by(& &1.mass, :desc)
      |> Enum.with_index()

    by_idx = Map.new(candidates, fn {frag, idx} -> {idx, frag} end)

    pairs = build_candidate_pairs(candidates, by_idx)

    needed_indices =
      pairs
      |> Enum.flat_map(fn {i, j} -> [i, j] end)
      |> Enum.uniq()

    norms = Map.new(needed_indices, fn idx -> {idx, Normalizer.normalize(by_idx[idx].ast)} end)

    pairs
    |> Enum.flat_map(fn {i, j} ->
      sim = EditDistance.similarity(norms[i], norms[j])
      if sim >= min_similarity, do: [{by_idx[i], by_idx[j], sim}], else: []
    end)
    |> deduplicate_pairs()
    |> Enum.map(&pair_to_clone/1)
  end

  defp build_candidate_pairs(indexed, by_idx) do
    inverted =
      Enum.reduce(indexed, %{}, fn {frag, idx}, acc ->
        Enum.reduce(frag.sub_hashes, acc, fn h, a ->
          Map.update(a, h, [idx], &[idx | &1])
        end)
      end)

    Enum.reduce(inverted, MapSet.new(), fn {_hash, indices}, pairs ->
      pairs_from_posting(indices, pairs, by_idx)
    end)
    |> MapSet.to_list()
  end

  defp pairs_from_posting(indices, pairs, by_idx) when length(indices) > @max_posting_list do
    # Candidates are pre-sorted by mass descending, so indices preserve that order
    pairs_from_posting(Enum.take(indices, @max_posting_list), pairs, by_idx)
  end

  defp pairs_from_posting(indices, pairs, by_idx) do
    for i <- indices,
        j <- indices,
        i < j,
        mass_compatible?(by_idx[i], by_idx[j]),
        not same_location?(by_idx[i], by_idx[j]),
        jaccard_compatible?(by_idx[i], by_idx[j]),
        reduce: pairs do
      acc -> MapSet.put(acc, {i, j})
    end
  end

  defp jaccard_compatible?(a, b) do
    sa = a.sub_hashes
    sb = b.sub_hashes

    if MapSet.size(sa) == 0 or MapSet.size(sb) == 0 do
      false
    else
      intersection = MapSet.intersection(sa, sb) |> MapSet.size()
      union = MapSet.union(sa, sb) |> MapSet.size()
      intersection / union >= @jaccard_threshold
    end
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
