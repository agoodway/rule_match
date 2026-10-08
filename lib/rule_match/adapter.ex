defmodule RuleMatch.Adapter do
  @moduledoc """
  A ruleset loader. Identifiers are nonblank strings whose meaning belongs
  to the adapter, such as a file path or a database key.

  Expected loading failures return error tuples. Unexpected runtime
  exceptions propagate to the caller.
  """

  @callback load(String.t(), keyword()) :: {:ok, RuleMatch.Ruleset.t()} | {:error, term()}
end
