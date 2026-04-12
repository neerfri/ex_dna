defmodule ExDNA.AST.Fingerprint do
  @moduledoc """
  Computes structural fingerprints (hashes) for AST subtrees.

  Every subtree whose *mass* (node count) meets the threshold is hashed.
  Two normalized ASTs with the same hash are structurally identical clones.

  Additionally, sliding windows over sibling sequences (consecutive statements
  in a block) are fingerprinted to catch clones that span multiple statements
  but don't align to a single subtree boundary.
  """

  alias ExDNA.AST.Normalizer

  @type hash :: binary()
  @type fragment :: %{
          hash: hash(),
          mass: pos_integer(),
          ast: Macro.t(),
          file: String.t(),
          line: pos_integer()
        }

  @max_window_size 6

  @doc """
  Walk an AST and return all subtree fragments that meet `min_mass`.

  Each fragment contains the normalized hash, mass, original AST (for display),
  source file, and starting line number.
  """
  @spec fragments(Macro.t(), String.t(), pos_integer(), keyword()) :: [fragment()]
  def fragments(ast, file, min_mass, opts \\ []) do
    norm_opts = Keyword.take(opts, [:literal_mode, :normalize_pipes])
    excluded = Keyword.get(opts, :excluded_macros, []) |> MapSet.new()
    {_ast, frags} = walk(ast, file, min_mass, norm_opts, excluded, [])
    frags
  end

  defp walk({:__block__, _meta, args} = node, file, min_mass, norm_opts, excluded, acc)
       when is_list(args) do
    acc =
      Enum.reduce(args, acc, fn child, a ->
        elem(walk(child, file, min_mass, norm_opts, excluded, a), 1)
      end)

    acc = sibling_windows(args, file, min_mass, norm_opts, acc)

    {node, acc}
  end

  defp walk({form, _meta, args} = node, file, min_mass, norm_opts, excluded, acc)
       when is_list(args) do
    if excluded_macro?(form, excluded) do
      {node, acc}
    else
      acc =
        Enum.reduce(args, acc, fn child, a ->
          elem(walk(child, file, min_mass, norm_opts, excluded, a), 1)
        end)

      mass = mass(node)

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
          line: line
        }

        {node, [frag | acc]}
      else
        {node, acc}
      end
    end
  end

  defp walk({left, right}, file, min_mass, norm_opts, excluded, acc) do
    {_, acc} = walk(left, file, min_mass, norm_opts, excluded, acc)
    {_, acc} = walk(right, file, min_mass, norm_opts, excluded, acc)
    {{left, right}, acc}
  end

  defp walk(list, file, min_mass, norm_opts, excluded, acc) when is_list(list) do
    acc =
      Enum.reduce(list, acc, fn item, a ->
        elem(walk(item, file, min_mass, norm_opts, excluded, a), 1)
      end)

    {list, acc}
  end

  defp walk(leaf, _file, _min_mass, _norm_opts, _excluded, acc), do: {leaf, acc}

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
        line: first_line(window)
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
