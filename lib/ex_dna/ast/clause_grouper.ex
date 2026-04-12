defmodule ExDNA.AST.ClauseGrouper do
  @moduledoc """
  Groups consecutive function clauses with the same name/arity into synthetic
  compound nodes so the fingerprinter can detect duplicated multi-clause functions.

  Also groups delegation wrappers with their target clause. A delegation is when
  a lower-arity clause simply calls the same function with extra default arguments:

      def fetch(id), do: fetch(id, [])
      def fetch(id, opts) do ... end

  These are grouped into a single `__ex_dna_grouped_def__` block so the fingerprinter
  can detect duplicated wrapper+body patterns across modules.
  """

  @def_forms [:def, :defp, :defmacro, :defmacrop]

  @doc """
  Walk the AST and group consecutive function clauses inside module bodies.
  """
  @spec group(Macro.t()) :: Macro.t()
  def group(ast) do
    Macro.prewalk(ast, fn
      {:defmodule, meta, [alias_node, [do: {:__block__, block_meta, body}]]}
      when is_list(body) ->
        grouped = body |> group_same_arity() |> group_delegations()
        {:defmodule, meta, [alias_node, [do: {:__block__, block_meta, grouped}]]}

      other ->
        other
    end)
  end

  defp group_same_arity(nodes) do
    nodes
    |> chunk_by_clause()
    |> Enum.flat_map(fn
      [single] -> [single]
      group -> [wrap_group(group)]
    end)
  end

  defp group_delegations(nodes), do: do_group_delegations(nodes, [])

  defp do_group_delegations([], acc), do: Enum.reverse(acc)

  defp do_group_delegations([node | rest], acc) do
    case delegation_target(node, rest) do
      {target, remaining} ->
        grouped = wrap_group([node, target])
        do_group_delegations(remaining, [grouped | acc])

      nil ->
        do_group_delegations(rest, [node | acc])
    end
  end

  defp delegation_target(wrapper, [target | rest]) do
    with {form, {name, wrapper_arity}} <- def_identity(wrapper),
         {^form, {^name, target_arity}} <- def_identity(target),
         true <- target_arity > wrapper_arity,
         true <- delegates_to_self?(wrapper, name) do
      {target, rest}
    else
      _ -> nil
    end
  end

  defp delegation_target(_wrapper, []), do: nil

  defp delegates_to_self?({form, _meta, [_call, [do: body]]}, name) when form in @def_forms do
    body_delegates?(body, name)
  end

  defp delegates_to_self?({form, _meta, [{:when, _, _}, [do: body]]}, name)
       when form in @def_forms do
    body_delegates?(body, name)
  end

  defp delegates_to_self?(_, _), do: false

  defp body_delegates?({name, _meta, args}, name) when is_atom(name) and is_list(args), do: true
  defp body_delegates?({:|>, _, [_, {name, _, _}]}, name), do: true
  defp body_delegates?(_, _), do: false

  defp chunk_by_clause(nodes), do: do_chunk(nodes, [])

  defp do_chunk([], acc), do: Enum.reverse(acc)

  defp do_chunk([node | rest], acc) do
    case def_identity(node) do
      nil ->
        do_chunk(rest, [[node] | acc])

      identity ->
        {same, remaining} = collect_same(rest, identity, [node])
        do_chunk(remaining, [Enum.reverse(same) | acc])
    end
  end

  defp collect_same([node | rest], identity, collected) do
    if def_identity(node) == identity do
      collect_same(rest, identity, [node | collected])
    else
      {collected, [node | rest]}
    end
  end

  defp collect_same([], _identity, collected), do: {collected, []}

  defp def_identity({form, _meta, [{:when, _, [call | _]}, _body]}) when form in @def_forms do
    {form, name_arity(call)}
  end

  defp def_identity({form, _meta, [call, _body]}) when form in @def_forms do
    {form, name_arity(call)}
  end

  defp def_identity({:__ex_dna_grouped_def__, _, [first | _]}) do
    def_identity(first)
  end

  defp def_identity(_), do: nil

  defp name_arity({name, _meta, args}) when is_atom(name) and is_list(args),
    do: {name, length(args)}

  defp name_arity({name, _meta, nil}) when is_atom(name), do: {name, 0}
  defp name_arity(_), do: nil

  defp wrap_group(clauses) do
    line = first_line(clauses)
    {:__ex_dna_grouped_def__, [line: line], clauses}
  end

  defp first_line([{_form, meta, _} | _]), do: Keyword.get(meta, :line, 0)
  defp first_line(_), do: 0
end
