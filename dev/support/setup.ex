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
           # Timestamp 2 re-enters Dev.Migration after timestamp 1 is already
           # recorded, so later evolver versions still apply.
           first = Ecto.Migrator.up(repo, 1, Migration, log: false)
           second = Ecto.Migrator.up(repo, 2, Migration, log: false)

           if first in [:ok, :already_up] and second in [:ok, :already_up] do
             :ok
           else
             {:error, {first, second}}
           end
         end) do
      {:ok, :ok, _apps} ->
        :ok

      {:ok, other, _apps} ->
        Mix.raise("Could not set up the RuleMatch database: #{inspect(other)}")

      {:error, reason} ->
        Mix.raise("Could not set up the RuleMatch database: #{inspect(reason)}")
    end
  rescue
    error in [DBConnection.ConnectionError, Postgrex.Error] ->
      Mix.raise("Could not connect to the RuleMatch database: #{Exception.message(error)}")
  end
end
