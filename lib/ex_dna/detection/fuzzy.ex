defmodule ExDNA.Detection.Fuzzy do
  @moduledoc """
  Type-III (near-miss) clone detection using characteristic vectors and LSH.

  Uses DECKARD-style characteristic vectors to quickly identify candidate
  clone pairs, then verifies with tree edit distance. This replaces the
  previous O(n²) pairwise comparison with LSH-bucketed candidate generation,
  reducing comparison count dramatically for large codebases.

  Detection pipeline:
  1. Filter out fragments already covered by exact clones
  2. Compute characteristic vectors for remaining candidates
  3. Generate LSH signatures from characteristic vectors
  4. Group fragments into buckets by LSH band
  5. Only compare pairs that share at least one bucket (candidate pairs)
  6. Verify candidates with cosine similarity pre-filter
  7. Final verification with tree edit distance
  """

  alias ExDNA.AST.{CharacteristicVector, EditDistance, Normalizer}
  alias ExDNA.Detection.Clone

  @mass_tolerance 0.3
  @num_hashes 64
  @band_size 8
  @cosine_pre_filter 0.5
  @max_bucket_size 50

  @doc """
  Find Type-III clones from a list of fragments at the given similarity threshold.

  Returns clone structs for every pair above the threshold that isn't
  already an exact match.
  """
  @spec detect([map()], float(), MapSet.t()) :: [Clone.t()]
  def detect(fragments, min_similarity, exact_hashes) do
    candidates =
      fragments
      |> Enum.reject(fn f -> MapSet.member?(exact_hashes, f.hash) end)
      |> Enum.sort_by(& &1.mass, :desc)

    if length(candidates) <= 200 do
      find_similar_pairs_brute(candidates, min_similarity)
    else
      find_similar_pairs_lsh(candidates, min_similarity)
    end
    |> deduplicate_pairs()
    |> Enum.map(&pair_to_clone/1)
  end

  defp find_similar_pairs_brute(fragments, min_similarity) do
    indexed = Enum.with_index(fragments)

    for {frag_a, i} <- indexed,
        {frag_b, j} <- indexed,
        j > i,
        mass_compatible?(frag_a, frag_b),
        not same_location?(frag_a, frag_b),
        sim = compute_similarity(frag_a, frag_b),
        sim >= min_similarity do
      {frag_a, frag_b, sim}
    end
  end

  defp find_similar_pairs_lsh(fragments, min_similarity) do
    vectorized =
      Enum.map(fragments, fn frag ->
        Map.put_new_lazy(frag, :vector, fn -> CharacteristicVector.compute(frag.ast) end)
      end)

    all_keys =
      vectorized
      |> Enum.flat_map(fn f -> Map.keys(f.vector) end)
      |> MapSet.new()

    hyperplanes = CharacteristicVector.generate_hyperplanes(all_keys, @num_hashes)

    indexed_fragments =
      vectorized
      |> Enum.with_index()
      |> Enum.map(fn {frag, idx} ->
        sig = CharacteristicVector.lsh_signature(frag.vector, hyperplanes)
        {frag, idx, sig}
      end)

    candidate_pairs = lsh_candidate_pairs(indexed_fragments)

    frag_by_idx = Map.new(indexed_fragments, fn {frag, idx, _sig} -> {idx, frag} end)

    candidate_pairs
    |> Task.async_stream(
      fn {i, j} ->
        frag_a = Map.fetch!(frag_by_idx, i)
        frag_b = Map.fetch!(frag_by_idx, j)

        with true <- mass_compatible?(frag_a, frag_b),
             false <- same_location?(frag_a, frag_b),
             true <- cosine_pre_filter?(frag_a, frag_b),
             sim when sim >= min_similarity <- compute_similarity(frag_a, frag_b) do
          {frag_a, frag_b, sim}
        else
          _ -> nil
        end
      end,
      max_concurrency: System.schedulers_online(),
      ordered: false
    )
    |> Enum.flat_map(fn
      {:ok, nil} -> []
      {:ok, result} -> [result]
    end)
  end

  defp lsh_candidate_pairs(indexed_fragments) do
    num_bands = div(@num_hashes, @band_size)

    0..(num_bands - 1)
    |> Enum.flat_map(fn band_idx ->
      start = band_idx * @band_size

      indexed_fragments
      |> Enum.group_by(fn {_frag, _idx, sig} -> Enum.slice(sig, start, @band_size) end)
      |> Enum.flat_map(fn {_band_hash, group} -> pairs_from_bucket(group) end)
    end)
    |> Enum.uniq()
  end

  defp pairs_from_bucket(group) when length(group) < 2, do: []
  defp pairs_from_bucket(group) when length(group) > @max_bucket_size, do: []

  defp pairs_from_bucket(group) do
    for {_fa, i, _sa} <- group,
        {_fb, j, _sb} <- group,
        j > i do
      {i, j}
    end
  end

  defp cosine_pre_filter?(frag_a, frag_b) do
    CharacteristicVector.cosine_similarity(frag_a.vector, frag_b.vector) >= @cosine_pre_filter
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
