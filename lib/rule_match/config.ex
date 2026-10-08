defmodule RuleMatch.Config do
  @moduledoc "Configuration resolution for ruleset loaders and database storage."

  @type error :: {:error, {:invalid_config, String.t()}}

  @doc "Resolve loader options, with caller options overriding application configuration."
  @spec loader(keyword()) :: {:ok, keyword()} | error()
  def loader(opts) do
    resolved = resolve(opts)
    adapter = Keyword.fetch!(resolved, :adapter)

    if loaded_module?(adapter) and function_exported?(adapter, :load, 2) do
      {:ok, resolved}
    else
      invalid("adapter must be a module exporting load/2, got: #{inspect(adapter)}")
    end
  end

  @doc "Resolve a Repo module and nonblank prefix without requiring a running Repo."
  @spec store(keyword()) :: {:ok, {module(), String.t()}} | error()
  def store(opts) do
    resolved = resolve(opts)
    repo = Keyword.fetch!(resolved, :repo)
    prefix = Keyword.fetch!(resolved, :prefix)

    cond do
      not repo_module?(repo) ->
        invalid("repo must be an Ecto.Repo module, got: #{inspect(repo)}")

      not is_binary(prefix) or String.trim(prefix) == "" ->
        invalid("prefix must be a nonblank string, got: #{inspect(prefix)}")

      true ->
        {:ok, {repo, prefix}}
    end
  end

  defp resolve(opts) do
    [
      adapter: Application.get_env(:rule_match, :adapter, RuleMatch.Adapters.File),
      repo: Application.get_env(:rule_match, :repo),
      prefix: Application.get_env(:rule_match, :prefix, "rule_match")
    ]
    |> Keyword.merge(opts)
  end

  defp repo_module?(repo) do
    loaded_module?(repo) and function_exported?(repo, :__adapter__, 0) and
      Ecto.Repo in (repo.module_info(:attributes)
                    |> Keyword.get_values(:behaviour)
                    |> List.flatten())
  end

  defp loaded_module?(module), do: is_atom(module) and Code.ensure_loaded?(module)

  defp invalid(message), do: {:error, {:invalid_config, message}}
end
