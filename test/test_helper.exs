ExUnit.start()

{:ok, _pid} = RuleMatch.Dev.Repo.start_link()
Ecto.Adapters.SQL.Sandbox.mode(RuleMatch.Dev.Repo, :manual)
