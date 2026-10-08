defmodule RuleMatch.Dev.Migration do
  @moduledoc false
  use Ecto.Migration

  def up, do: RuleMatch.Migration.up(prefix: prefix() || "rule_match")
  def down, do: RuleMatch.Migration.down(prefix: prefix() || "rule_match")
end
