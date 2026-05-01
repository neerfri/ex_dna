defmodule ExDNA.CLI.Options do
  @moduledoc false

  def optional_values(opts, key) do
    case Keyword.get_values(opts, key) do
      [] -> nil
      values -> values
    end
  end

  def maybe_put(opts, _key, nil), do: opts
  def maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
