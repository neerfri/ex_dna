defmodule ExDNA.Detection.Fuzzy do
  @moduledoc """
  Type-III (near-miss) clone detection using characteristic vectors.

  Uses DECKARD-style characteristic vectors for fast candidate pre-filtering,
  then verifies with tree edit distance. Fragments are grouped by mass range
  to limit comparisons, then cosine similarity on structural vectors prunes
  pairs before expensive tree comparison.
  """

  alias ExDNA.AST.{CharacteristicVector, EditDistance, Normalizer}
  alias ExDNA.Detection.Clone

  @mass_tolerance 0.3
  @cosine_threshold 0.7
  @max_candidates 2000

  @doc """
  Find Type-III clones from a list of fragments at the given similarity threshold.

  Returns clone structs for every pair above the threshold that isn't
  already an exact match.
  """
  @spec detect([map()], float(), MapSet.t()) :: [Clone.t()]
  def detect(fragments, min_similarity, exact_hashes) do
    fragments
    |> Enum.reject(fn f -> MapSet.member?(exact_hashes, f.hash) end)
    |> Enum.sort_by(& &1.mass, :desc)
    |> Enum.take(@max_candidates)
    |> attach_vectors()
    |> group_by_mass_bucket()
    |> Enum.flat_map(fn bucket -> find_pairs_in_bucket(bucket, min_similarity) end)
    |> deduplicate_pairs()
    |> Enum.map(&pair_to_clone/1)
  end

  defp attach_vectors(fragments) do
    Enum.map(fragments, fn frag ->
      Map.put(frag, :vector, CharacteristicVector.compute(frag.ast))
    end)
  end

  defp group_by_mass_bucket(fragments) do
    fragments
    |> Enum.sort_by(& &1.mass, :desc)
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

    for {frag_a, i} <- indexed,
        {frag_b, j} <- indexed,
        j > i,
        mass_compatible?(frag_a, frag_b),
        not same_location?(frag_a, frag_b),
        cosine_compatible?(frag_a, frag_b),
        sim = compute_similarity(frag_a, frag_b),
        sim >= min_similarity do
      {frag_a, frag_b, sim}
    end
  end

  defp cosine_compatible?(frag_a, frag_b) do
    CharacteristicVector.cosine_similarity(frag_a.vector, frag_b.vector) >= @cosine_threshold
  end

  defp mass_compatible?(a, b) do
    ratio = min(a.mass, b.mass) / max(a.mass, b.mass)
    ratio >= 1.0 - @mass_tolerance
  end

  defp same_location?(a, b) do
    a.file == b.file and a.line == b.line
  end

  defp compute_similarity(frag_a, frag_b) do
    norm_a = Normalizer.normalize(frag_a.ast)
    norm_b = Normalizer.normalize(frag_b.ast)
    EditDistance.similarity(norm_a, norm_b)
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
