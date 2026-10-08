defmodule RuleMatch.Ruleset do
  @moduledoc """
  A rule set loaded from data: rules, the rosters they reference, and how to
  normalize a candidate before matching.

  A ruleset file is JSON:

      {
        "format": 1,
        "name": "coverage",
        "version": "2026-01-01",
        "description": "...",
        "normalize": {
          "downcase": ["payer", "plan_type"],
          "dates": ["date_of_service"]
        },
        "rules": [
          {
            "id": "acme_ppo",
            "priority": 10,
            "conditions": [{"op": "eq", "field": "payer", "value": "acme"}],
            "outcome": {"network_status": "in_network"}
          }
        ],
        "rosters": {
          "network_a": [
            {"provider": "provider_a", "products": ["basic"], "effective_on": "2024-08-15", "terminates_on": null}
          ]
        }
      }

  See `RuleMatch.Codec` for every condition shape. `load/1` and `save/2`
  round-trip: `ruleset |> to_json() |> from_json()` gives back the same rules
  and rosters.

  `normalize.downcase` fields are trimmed and downcased on the candidate.
  `normalize.dates` fields holding an ISO date string become `Date`s.
  """

  alias RuleMatch.{Codec, Rule}

  @format 1

  defstruct name: nil,
            version: nil,
            description: nil,
            normalize: %{downcase: [], dates: []},
            rules: [],
            rosters: %{},
            meta: %{}

  @type t :: %__MODULE__{
          name: String.t() | nil,
          version: String.t() | nil,
          description: String.t() | nil,
          normalize: %{downcase: [String.t()], dates: [String.t()]},
          rules: [Rule.t()],
          rosters: RuleMatch.Roster.t(),
          meta: map()
        }

  @doc """
  Build a ruleset in code. Rules are compiled with `RuleMatch.compile/1`.

  Mostly for tests and for exporting; production rules belong in a file.
  """
  @spec new(keyword()) :: t()
  def new(attrs \\ []) do
    normalize = Keyword.get(attrs, :normalize, %{})

    %__MODULE__{
      name: Keyword.get(attrs, :name),
      version: Keyword.get(attrs, :version),
      description: Keyword.get(attrs, :description),
      normalize: %{
        downcase: Enum.map(Map.get(normalize, :downcase, []), &to_string/1),
        dates: Enum.map(Map.get(normalize, :dates, []), &to_string/1)
      },
      rules: RuleMatch.compile(Keyword.get(attrs, :rules, [])),
      rosters: Keyword.get(attrs, :rosters, %{}),
      meta: Keyword.get(attrs, :meta, %{})
    }
  end

  @doc "Read and decode a ruleset file."
  @spec load(Path.t()) :: {:ok, t()} | {:error, term()}
  def load(path) do
    with {:ok, json} <- File.read(path) do
      from_json(json)
    end
  end

  @doc "Like `load/1`, raising on error."
  @spec load!(Path.t()) :: t()
  def load!(path) do
    case load(path) do
      {:ok, ruleset} ->
        ruleset

      {:error, reason} ->
        raise ArgumentError, "cannot load ruleset #{path}: #{format_error(reason)}"
    end
  end

  @doc "Encode and write a ruleset file."
  @spec save(t(), Path.t()) :: :ok | {:error, term()}
  def save(%__MODULE__{} = ruleset, path), do: File.write(path, to_json(ruleset))

  @doc "Decode a ruleset from a JSON string."
  @spec from_json(String.t()) :: {:ok, t()} | {:error, term()}
  def from_json(json) when is_binary(json) do
    case JSON.decode(json) do
      {:ok, map} -> from_map(map)
      {:error, reason} -> {:error, {:invalid_json, reason}}
    end
  end

  @doc "Encode a ruleset as pretty-printed JSON."
  @spec to_json(t()) :: String.t()
  def to_json(%__MODULE__{} = ruleset), do: ruleset |> to_map() |> Codec.pretty()

  @doc "Build a ruleset from decoded JSON (string keys)."
  @spec from_map(map()) :: {:ok, t()} | {:error, term()}
  def from_map(%{} = map) do
    with :ok <- check_format(Map.get(map, "format", @format)) do
      normalize = Map.get(map, "normalize", %{})

      {:ok,
       %__MODULE__{
         name: Map.get(map, "name"),
         version: Map.get(map, "version"),
         description: Map.get(map, "description"),
         normalize: %{
           downcase: Map.get(normalize, "downcase", []),
           dates: Map.get(normalize, "dates", [])
         },
         rules:
           map |> Map.get("rules", []) |> Enum.map(&Codec.rule_from_map/1) |> RuleMatch.compile(),
         rosters: Codec.rosters_from_map(Map.get(map, "rosters", %{})),
         meta: Map.get(map, "meta", %{})
       }}
    end
  rescue
    e in ArgumentError -> {:error, {:invalid_ruleset, Exception.message(e)}}
  end

  def from_map(other),
    do: {:error, {:invalid_ruleset, "expected an object, got: #{inspect(other)}"}}

  @doc "The ruleset as JSON-ready data (string keys)."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = ruleset) do
    %{
      "format" => @format,
      "normalize" => %{
        "downcase" => ruleset.normalize.downcase,
        "dates" => ruleset.normalize.dates
      },
      "rules" => Enum.map(ruleset.rules, &Codec.rule_to_map/1),
      "rosters" => Codec.rosters_to_map(ruleset.rosters)
    }
    |> put_present("name", ruleset.name)
    |> put_present("version", ruleset.version)
    |> put_present("description", ruleset.description)
    |> put_present(
      "meta",
      if(ruleset.meta == %{}, do: nil, else: Codec.to_json_value(ruleset.meta))
    )
  end

  @doc """
  Apply the ruleset's normalization to a candidate.

  String keys that name an existing atom become atom keys. Unknown keys and
  fields not listed in `normalize` are kept as they are.
  """
  @spec normalize(t(), map()) :: map()
  def normalize(%__MODULE__{normalize: spec}, candidate) when is_map(candidate) do
    candidate = atomize_keys(candidate)

    candidate =
      Enum.reduce(spec.dates, candidate, fn field, acc ->
        update_field(acc, field, &parse_date/1)
      end)

    Enum.reduce(spec.downcase, candidate, fn field, acc ->
      update_field(acc, field, fn
        value when is_binary(value) -> value |> String.trim() |> String.downcase()
        value -> value
      end)
    end)
  end

  @doc "Human-readable form of an error returned by `load/1` or `from_json/1`."
  @spec format_error(term()) :: String.t()
  def format_error({:invalid_ruleset, message}), do: message
  def format_error({:invalid_json, reason}), do: "invalid JSON: #{inspect(reason)}"

  def format_error({:unsupported_format, format}),
    do: "unsupported ruleset format #{inspect(format)}"

  def format_error(reason) when is_atom(reason), do: :file.format_error(reason) |> to_string()
  def format_error(reason), do: inspect(reason)

  defp check_format(@format), do: :ok
  defp check_format(format), do: {:error, {:unsupported_format, format}}

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp update_field(candidate, field, fun) do
    key =
      Enum.find([existing_atom(field), field], &(&1 != nil and Map.has_key?(candidate, &1)))

    if key, do: Map.update!(candidate, key, fun), else: candidate
  end

  defp existing_atom(field) do
    String.to_existing_atom(field)
  rescue
    ArgumentError -> nil
  end

  defp atomize_keys(candidate) do
    Map.new(candidate, fn
      {key, value} when is_binary(key) -> {existing_atom(key) || key, value}
      pair -> pair
    end)
  end

  defp parse_date(%DateTime{} = datetime), do: DateTime.to_date(datetime)
  defp parse_date(%NaiveDateTime{} = datetime), do: NaiveDateTime.to_date(datetime)

  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(String.trim(value)) do
      {:ok, date} -> date
      _ -> value
    end
  end

  defp parse_date(value), do: value
end
