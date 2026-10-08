defmodule RuleMatch.Adapter do
  @moduledoc """
  A ruleset loader. Identifiers are nonblank strings whose meaning belongs
  to the adapter, such as a file path or a database key.

  Expected loading failures return error tuples. Unexpected runtime
  exceptions propagate to the caller.

  `RuleMatch.Ruleset.load/2` passes resolved application configuration with
  per-call overrides to `load/2`. Implementations return runtime
  `RuleMatch.Ruleset` structs. The contract covers reads; persistence is
  provided separately by `RuleMatch.Store`.
  """

  @callback load(String.t(), keyword()) :: {:ok, RuleMatch.Ruleset.t()} | {:error, term()}
end
