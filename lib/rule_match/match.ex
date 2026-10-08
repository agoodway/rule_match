defmodule RuleMatch.Match do
  @moduledoc """
  One rule that matched a candidate, with the score used to rank it
  and a per-condition explanation.
  """

  defstruct [:rule, :priority, :specificity, :score, :outcome, :explanation]

  @type t :: %__MODULE__{
          rule: RuleMatch.Rule.t(),
          priority: integer(),
          specificity: non_neg_integer(),
          score: {integer(), non_neg_integer()},
          outcome: map(),
          explanation: [map()]
        }
end
