defmodule ExDNA.AST.Fingerprint do
  @moduledoc """
  Computes structural fingerprints (hashes) for AST subtrees.

  Every subtree whose *mass* (node count) meets the threshold is hashed.
  Two normalized ASTs with the same hash are structurally identical clones.

  Each fragment also carries a set of lightweight sub-hashes from its
  children (computed during the same walk) for efficient Jaccard-based
  fuzzy candidate pruning.

  Additionally, sliding windows over sibling sequences in module bodies
  are fingerprinted to catch clones that span multiple adjacent statements.
  """

  alias ExDNA.AST.Normalizer

  @type hash :: binary()
  @type fragment :: %{
          hash: hash(),
          mass: pos_integer(),
          ast: Macro.t(),
          file: String.t(),
          line: pos_integer(),
          sub_hashes: MapSet.t(integer())
        }

  @max_window_size 4
  @sub_hash_min_mass 5
  @module_level_forms [:def, :defp, :defmacro, :defmacrop]

  @doc """
  Walk an AST and return all subtree fragments that meet `min_mass`.
  """
  @spec fragments(Macro.t(), String.t(), pos_integer(), keyword()) :: [fragment()]
  def fragments(ast, file, min_mass, opts \\ []) do
    norm_opts = Keyword.take(opts, [:literal_mode, :normalize_pipes])
    excluded = Keyword.get(opts, :excluded_macros, []) |> MapSet.new()
    {_ast, frags, _sub_hashes} = walk(ast, file, min_mass, norm_opts, excluded, [], MapSet.new())
    frags
  end

  # __block__ — walk children, optionally generate sibling windows, don't fingerprint the block itself
  defp walk(
         {:__block__, _meta, args} = node,
         file,
         min_mass,
         norm_opts,
         excluded,
         acc,
         _parent_subs
       )
       when is_list(args) do
    {acc, child_subs} =
      Enum.reduce(args, {acc, MapSet.new()}, fn child, {a, subs} ->
        {_, a, child_s} = walk(child, file, min_mass, norm_opts, excluded, a, MapSet.new())
        {a, MapSet.union(subs, child_s)}
      end)

    acc =
      if module_body?(args) do
        sibling_windows(args, file, min_mass, norm_opts, acc)
      else
        acc
      end

    {node, acc, child_subs}
  end

  # Regular call nodes — walk children, fingerprint if large enough
  defp walk({form, _meta, args} = node, file, min_mass, norm_opts, excluded, acc, _parent_subs)
       when is_list(args) do
    if excluded_macro?(form, excluded) do
      {node, acc, MapSet.new()}
    else
      {acc, child_subs} =
        Enum.reduce(args, {acc, MapSet.new()}, fn child, {a, subs} ->
          {_, a, child_s} = walk(child, file, min_mass, norm_opts, excluded, a, MapSet.new())
          {a, MapSet.union(subs, child_s)}
        end)

      mass = mass(node)

      # Collect lightweight sub-hash for this node (used by parent's Jaccard set)
      my_sub_hash =
        if mass >= @sub_hash_min_mass do
          MapSet.new([:erlang.phash2({form, mass})])
        else
          MapSet.new()
        end

      all_subs = MapSet.union(child_subs, my_sub_hash)

      if mass >= min_mass do
        normalized = Normalizer.normalize(node, norm_opts)
        hash = compute_hash(normalized)
        {_form, meta, _args} = node
        line = Keyword.get(meta, :line, 0)

        frag = %{
          hash: hash,
          mass: mass,
          ast: node,
          file: file,
          line: line,
          sub_hashes: all_subs
        }

        {node, [frag | acc], all_subs}
      else
        {node, acc, all_subs}
      end
    end
  end

  defp walk({left, right}, file, min_mass, norm_opts, excluded, acc, _parent_subs) do
    {_, acc, subs_l} = walk(left, file, min_mass, norm_opts, excluded, acc, MapSet.new())
    {_, acc, subs_r} = walk(right, file, min_mass, norm_opts, excluded, acc, MapSet.new())
    {{left, right}, acc, MapSet.union(subs_l, subs_r)}
  end

  defp walk(list, file, min_mass, norm_opts, excluded, acc, _parent_subs) when is_list(list) do
    {acc, subs} =
      Enum.reduce(list, {acc, MapSet.new()}, fn item, {a, s} ->
        {_, a, child_s} = walk(item, file, min_mass, norm_opts, excluded, a, MapSet.new())
        {a, MapSet.union(s, child_s)}
      end)

    {list, acc, subs}
  end

  defp walk(leaf, _file, _min_mass, _norm_opts, _excluded, acc, _parent_subs),
    do: {leaf, acc, MapSet.new()}

  defp module_body?(children) when length(children) > 30, do: false

  defp module_body?(children) do
    Enum.any?(children, fn
      {form, _, _} when form in @module_level_forms -> true
      _ -> false
    end)
  end

  defp sibling_windows(children, _file, _min_mass, _norm_opts, acc) when length(children) < 2,
    do: acc

  defp sibling_windows(children, file, min_mass, norm_opts, acc) do
    len = length(children)
    max_win = min(@max_window_size, len)

    Enum.reduce(2..max_win//1, acc, fn window_size, acc_outer ->
      children
      |> Enum.chunk_every(window_size, 1, :discard)
      |> Enum.reduce(acc_outer, fn window, acc_inner ->
        maybe_window_fragment(window, file, min_mass, norm_opts, acc_inner)
      end)
    end)
  end

  defp maybe_window_fragment(window, file, min_mass, norm_opts, acc) do
    combined_mass = Enum.sum(Enum.map(window, &mass/1))

    if combined_mass < min_mass do
      acc
    else
      synthetic = {:__block__, [], window}
      normalized = Normalizer.normalize(synthetic, norm_opts)
      hash = compute_hash(normalized)

      frag = %{
        hash: hash,
        mass: combined_mass,
        ast: synthetic,
        file: file,
        line: first_line(window),
        sub_hashes: MapSet.new()
      }

      [frag | acc]
    end
  end

  defp first_line([{_form, meta, _args} | _]), do: Keyword.get(meta, :line, 0)
  defp first_line(_), do: 0

  defp excluded_macro?(form, excluded) when is_atom(form), do: MapSet.member?(excluded, form)
  defp excluded_macro?(_, _), do: false

  @doc """
  Count the number of AST nodes in a tree (its "mass").
  """
  @spec mass(Macro.t()) :: non_neg_integer()
  def mass({_form, _meta, args}) when is_list(args) do
    1 + Enum.sum(Enum.map(args, &mass/1))
  end

  def mass({left, right}), do: 1 + mass(left) + mass(right)

  def mass(list) when is_list(list) do
    Enum.sum(Enum.map(list, &mass/1))
  end

  def mass(_leaf), do: 1

  @doc """
  Compute a deterministic hash for a normalized AST.
  """
  @spec compute_hash(Macro.t()) :: hash()
  def compute_hash(normalized_ast) do
    normalized_ast
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:blake2b, &1))
  end
end
