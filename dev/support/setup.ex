defmodule RuleMatch.Dev.Setup do
  @moduledoc false

  alias RuleMatch.Dev.{Migration, UnboxedRepo}

  @spec run() :: :ok
  def run do
    case UnboxedRepo.__adapter__().storage_up(UnboxedRepo.config()) do
      :ok -> :ok
      {:error, :already_up} -> :ok
      {:error, reason} -> Mix.raise("Could not create the RuleMatch database: #{inspect(reason)}")
    end

    case Ecto.Migrator.with_repo(UnboxedRepo, fn repo ->
           Ecto.Migrator.up(repo, 1, Migration, log: false)
         end) do
      {:ok, result, _apps} when result in [:ok, :already_up] -> :ok
      {:error, reason} -> Mix.raise("Could not set up the RuleMatch database: #{inspect(reason)}")
    end
  rescue
    error in [DBConnection.ConnectionError, Postgrex.Error] ->
      Mix.raise("Could not connect to the RuleMatch database: #{Exception.message(error)}")
  end
end
