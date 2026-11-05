defmodule Relay.ChannelDeclarations do
  @moduledoc """
  The channel adapter declarations as data (CH-2, CH-71) and the channel delivery semantics table (DS-12, INV-5). Each adapter carries its declaration in the repository under `priv/channels/<provider>/`:

    * `declaration.json`: `provider`, `adapter_version`, `channels`, `compiled_at`, `sources`, `deprecations`, the capability flags per channel (`capabilities`), the `provider_idempotency_policy`, the `paid_channels`, the price and limit data (`pricing`, `limits`), the `data_residency` and the `inbound_verification` declaration;
    * `evidence.json`: its `channel_event_evidence` rows (DS-10), one per channel and event code;
    * `errors.json`: its failure class mapping, one row per provider code (CH-7);
    * `vectors.json`: its test vectors, at least one per provider code (DS-11).

  `priv/channels/semantics.json` holds the delivery semantics row of every channel. `compose/1` joins them into the content of the versioned data set `channel_event_evidence` (OP-65), which the bundled data set loader publishes, so a later change needs no deploy and is audited. `new/2` builds a snapshot from the content of one version.

  A provider whose declaration is incomplete is registered but receives no traffic (CH-2, C-44): `gate/2` lists what is missing. An event code that has no evidence row is rejected (DS-10), and a provider code without a mapping is classified `unknown` (CH-8, INV-46).
  """

  @files ~w(declaration.json evidence.json errors.json vectors.json)
  @lists ~w(evidence errors vectors)
  @core_events ~w(accepted rejected uncertain)
  @capabilities ~w(delivery_receipts read_receipts collapse ttl update recall
                   business_initiated inbound)
  @modes ~w(wait_and_query retry_accepting_duplicate_risk no_auto_retry)
  @compensating ~w(secret_token basic_ip_allowlist)
  @unmapped %{
    "class" => "unknown",
    "condition" => nil,
    "event_code" => "rejected",
    "suppressed_success" => false
  }

  @enforce_keys [:version_id]
  defstruct version_id: nil, providers: %{}, semantics: %{}, evidence: %{}, errors: %{}

  @type row :: %{required(String.t()) => term()}
  @type declaration :: %{required(String.t()) => term()}
  @type missing ::
          :declaration
          | :capabilities
          | :provider_idempotency_policy
          | :error_map
          | :test_vectors
          | :evidence
          | :pricing
          | :limits
          | :data_residency
          | :inbound_verification
          | :semantics
  @type t :: %__MODULE__{
          version_id: Relay.Id.t() | nil,
          providers: %{String.t() => declaration()},
          semantics: %{String.t() => row()},
          evidence: %{{String.t(), String.t(), String.t()} => row()},
          errors: %{String.t() => %{String.t() => row()}}
        }

  @doc "The directory of the declarations bundled with the release."
  @spec root() :: Path.t()
  def root, do: Path.join(:code.priv_dir(:relay), "channels")

  # CH-71
  # DS-12
  @doc """
  Joins the declarations under `dir` into the content of the `channel_event_evidence` data set: `%{"semantics" => rows, "providers" => declarations}`, the providers in name order. A provider directory holds only the four declaration files, is named after its `provider` and must have a `declaration.json`; a missing evidence, error or vector file is an empty list, which `gate/2` reports.
  """
  @spec compose(Path.t()) :: {:ok, map()} | {:error, Relay.Error.t()}
  def compose(dir \\ root()) do
    with {:ok, semantics} <- json(dir, "semantics.json"),
         {:ok, names} <- provider_names(dir),
         {:ok, providers} <- providers(dir, names) do
      {:ok, %{"semantics" => semantics, "providers" => providers}}
    end
  end

  defp provider_names(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        {dirs, files} = Enum.split_with(entries, &File.dir?(Path.join(dir, &1)))

        case files -- ["semantics.json"] do
          [] -> {:ok, Enum.sort(dirs)}
          [file | _] -> error("unexpected file #{file}")
        end

      {:error, _reason} ->
        error("the declaration directory is not readable")
    end
  end

  defp providers(dir, names) do
    Enum.reduce_while(names, {:ok, []}, fn name, {:ok, acc} ->
      case provider(dir, name) do
        {:ok, declaration} -> {:cont, {:ok, [declaration | acc]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> then(fn
      {:ok, declarations} -> {:ok, Enum.reverse(declarations)}
      error -> error
    end)
  end

  defp provider(dir, name) do
    path = Path.join(dir, name)

    with {:ok, files} <- File.ls(path),
         [] <- files -- @files,
         {:ok, %{"provider" => ^name} = declaration} <- json(path, "declaration.json"),
         {:ok, lists} <- lists(path, files) do
      {:ok, Map.merge(declaration, lists)}
    else
      [file | _] -> error("unexpected file #{name}/#{file}")
      {:ok, %{}} -> error("#{name}/declaration.json names another provider")
      {:ok, _other} -> error("#{name}/declaration.json is not an object")
      {:error, %Relay.Error{} = error} -> {:error, error}
      {:error, _reason} -> error("#{name} is not readable")
    end
  end

  defp lists(path, files) do
    Enum.reduce_while(@lists, {:ok, %{}}, fn list, {:ok, acc} ->
      file = list <> ".json"

      case if(file in files, do: json(path, file), else: {:ok, []}) do
        {:ok, rows} when is_list(rows) -> {:cont, {:ok, Map.put(acc, list, rows)}}
        {:ok, _other} -> {:halt, error("#{file} is not a list")}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp json(dir, file) do
    with {:ok, text} <- File.read(Path.join(dir, file)),
         {:ok, value} <- Jason.decode(text) do
      {:ok, value}
    else
      _unreadable -> error("#{file} is not readable JSON")
    end
  end

  # CH-71
  # DS-10
  @doc """
  Checks the rules of a `channel_event_evidence` version that its JSON Schema cannot express: one semantics row per channel, one declaration per provider, one evidence row per channel and event code of a provider, only the provider's own channels in its evidence, capabilities and paid channels, and one mapping per provider code. Completeness is not checked here: an incomplete declaration is published and kept from traffic by `gate/2`.
  """
  @spec validate(map()) :: :ok | {:error, Relay.Error.t()}
  def validate(%{} = content) do
    semantics = list(content, "semantics")
    providers = list(content, "providers")

    base = [
      unique_semantics: unique?(semantics, &[&1["channel"]]),
      unique_providers: unique?(providers, &[&1["provider"]])
    ]

    checks = base ++ Enum.flat_map(providers, &provider_checks/1)

    case Enum.find(checks, fn {_rule, ok?} -> not ok? end) do
      nil ->
        :ok

      {rule, false} ->
        {:error,
         Relay.Error.new(:invalid_content, "channel_event_evidence breaks a consistency rule", %{
           rule: rule
         })}
    end
  end

  defp provider_checks(declaration) do
    channels = list(declaration, "channels")
    evidence = list(declaration, "evidence")
    capabilities = Map.keys(Map.get(declaration, "capabilities") || %{})

    [
      unique_evidence: unique?(evidence, &[&1["channel"], &1["event_code"]]),
      evidence_channels: Enum.all?(evidence, &(&1["channel"] in channels)),
      capability_channels: Enum.all?(capabilities, &(&1 in channels)),
      paid_channels: Enum.all?(list(declaration, "paid_channels"), &(&1 in channels)),
      unique_codes: unique?(list(declaration, "errors"), &[&1["code"]])
    ]
  end

  # OP-65 (4)
  @doc "Builds a snapshot from the content of a `channel_event_evidence` version and its identifier (`nil` for content composed from the repository)."
  @spec new(map(), Relay.Id.t() | nil) :: t()
  def new(%{} = content, version_id) do
    providers = list(content, "providers")

    %__MODULE__{
      version_id: version_id,
      providers: Map.new(providers, &{&1["provider"], &1}),
      semantics: Map.new(list(content, "semantics"), &{&1["channel"], &1}),
      evidence: Map.new(Enum.flat_map(providers, &evidence_rows/1)),
      errors: Map.new(providers, &error_index/1)
    }
  end

  defp error_index(declaration),
    do: {declaration["provider"], Map.new(list(declaration, "errors"), &{&1["code"], &1})}

  defp evidence_rows(declaration) do
    for row <- list(declaration, "evidence"),
        do: {{declaration["provider"], row["channel"], row["event_code"]}, row}
  end

  @doc "The providers that have a declaration, in name order."
  @spec providers(t()) :: [String.t()]
  def providers(%__MODULE__{} = s), do: s.providers |> Map.keys() |> Enum.sort()

  @doc "The declaration of a provider."
  @spec declaration(t(), String.t()) :: {:ok, declaration()} | {:error, :unknown_provider}
  def declaration(%__MODULE__{} = s, provider) do
    case Map.fetch(s.providers, provider) do
      {:ok, declaration} -> {:ok, declaration}
      :error -> {:error, :unknown_provider}
    end
  end

  # CH-2
  # DS-11
  # DS-12
  # INV-13
  # C-44
  @doc """
  The activation gate of a provider (DS-11, CH-2): `:ok` when its declaration is complete, otherwise the list of what is missing. Complete means: capability flags for every channel; a `provider_idempotency_policy` (INV-13), which names a status query when it waits and queries; a non-empty failure class mapping; a test vector for every provider code whose expectation matches the mapping; evidence rows for `accepted`, `rejected`, `uncertain` and every mapped event code on every channel; price units for every channel and the three limit lists; data residency with the transfer basis and, under standard contractual clauses, their notification date; an inbound verification method, compensating controls marked unverifiable and no method only when no channel takes inbound messages; and a delivery semantics row for every channel (DS-12).
  """
  @spec gate(t(), String.t()) :: :ok | {:error, [missing(), ...]}
  def gate(%__MODULE__{} = s, provider) do
    case declaration(s, provider) do
      {:ok, declaration} ->
        checks = [
          capabilities: capabilities?(declaration),
          provider_idempotency_policy: idempotency?(declaration),
          error_map: list(declaration, "errors") != [],
          test_vectors: vectors?(s, declaration),
          evidence: evidence?(s, declaration),
          pricing: pricing?(declaration),
          limits: limits?(declaration),
          data_residency: residency?(declaration),
          inbound_verification: inbound?(declaration),
          semantics: Enum.all?(channels(declaration), &Map.has_key?(s.semantics, &1))
        ]

        case for({check, false} <- checks, do: check) do
          [] -> :ok
          missing -> {:error, missing}
        end

      {:error, :unknown_provider} ->
        {:error, [:declaration]}
    end
  end

  defp capabilities?(declaration) do
    flags = Map.get(declaration, "capabilities") || %{}

    Enum.all?(channels(declaration), fn channel ->
      case Map.get(flags, channel) do
        %{} = set -> Enum.all?(@capabilities, &is_boolean(Map.get(set, &1)))
        _missing -> false
      end
    end)
  end

  defp idempotency?(declaration) do
    case Map.get(declaration, "provider_idempotency_policy") do
      %{"mode" => "wait_and_query", "status_query" => true} -> true
      %{"mode" => "wait_and_query"} -> false
      %{"mode" => mode} -> mode in @modes
      _missing -> false
    end
  end

  defp vectors?(s, declaration) do
    provider = declaration["provider"]
    vectors = list(declaration, "vectors")
    covered = MapSet.new(vectors, &get_in(&1, ["raw", "code"]))

    Enum.all?(list(declaration, "errors"), &MapSet.member?(covered, &1["code"])) and
      Enum.all?(vectors, &(expectation(s, provider, get_in(&1, ["raw", "code"])) == &1["expect"]))
  end

  defp evidence?(s, declaration) do
    provider = declaration["provider"]
    codes = Enum.uniq(@core_events ++ Enum.map(list(declaration, "errors"), & &1["event_code"]))

    for(channel <- channels(declaration), code <- codes, do: {provider, channel, code})
    |> Enum.all?(&Map.has_key?(s.evidence, &1))
  end

  defp pricing?(declaration) do
    case Map.get(declaration, "pricing") do
      %{"currency" => currency, "units" => %{} = units, "prices" => prices}
      when is_binary(currency) and is_list(prices) ->
        Enum.all?(channels(declaration), &Map.has_key?(units, &1))

      _missing ->
        false
    end
  end

  defp limits?(declaration) do
    case Map.get(declaration, "limits") do
      %{"account" => a, "sender" => s, "recipient" => r} ->
        is_list(a) and is_list(s) and is_list(r)

      _missing ->
        false
    end
  end

  defp residency?(declaration) do
    case Map.get(declaration, "data_residency") do
      %{"transfer_basis" => "scc", "scc_notified_on" => nil} -> false
      %{"in_installation" => true, "transfer_basis" => basis} -> is_binary(basis)
      %{"processing_countries" => [_ | _], "transfer_basis" => basis} -> is_binary(basis)
      _missing -> false
    end
  end

  defp inbound?(declaration) do
    case Map.get(declaration, "inbound_verification") do
      %{"method" => "none"} -> not inbound_channel?(declaration)
      %{"method" => method, "authenticity" => "verified"} -> method not in @compensating
      %{"method" => method, "authenticity" => "unverifiable"} -> is_binary(method)
      _missing -> false
    end
  end

  defp inbound_channel?(declaration) do
    capabilities = Map.get(declaration, "capabilities") || %{}
    Enum.any?(Map.values(capabilities), &match?(%{"inbound" => true}, &1))
  end

  # CH-7
  # CH-8
  # INV-46
  @doc "Finds the failure class mapping of a provider code; a code without a mapping is `:unmapped` and is classified `unknown`, never guessed."
  @spec mapping(t(), String.t(), String.t()) :: {:ok, row()} | :unmapped
  def mapping(%__MODULE__{} = s, provider, code) when is_binary(code) do
    case s.errors |> Map.get(provider, %{}) |> Map.fetch(code) do
      {:ok, row} -> {:ok, row}
      :error -> :unmapped
    end
  end

  # DS-11
  @doc "The normalized expectation of a provider code, as a test vector states it: class, condition, event code and whether a provider success was a suppression."
  @spec expectation(t(), String.t(), String.t() | nil) :: %{String.t() => term()}
  def expectation(%__MODULE__{} = s, provider, code) when is_binary(code) do
    case mapping(s, provider, code) do
      {:ok, row} -> Map.take(row, ~w(class condition event_code suppressed_success))
      :unmapped -> @unmapped
    end
  end

  def expectation(%__MODULE__{}, _provider, _code), do: @unmapped

  # DS-10
  @doc "The evidence row of a provider's event code on a channel; an event code without a row is rejected."
  @spec evidence(t(), String.t(), String.t(), String.t()) ::
          {:ok, row()} | {:error, :unknown_event}
  def evidence(%__MODULE__{} = s, provider, channel, event_code) do
    case Map.fetch(s.evidence, {provider, channel, event_code}) do
      {:ok, row} -> {:ok, row}
      :error -> {:error, :unknown_event}
    end
  end

  # DS-12
  @doc "The delivery semantics row of a channel; a channel without one is never activated."
  @spec semantics(t(), String.t()) :: {:ok, row()} | {:error, :missing}
  def semantics(%__MODULE__{} = s, channel) do
    case Map.fetch(s.semantics, channel) do
      {:ok, row} -> {:ok, row}
      :error -> {:error, :missing}
    end
  end

  # T-28
  @doc "Returns true when the provider declares `channel` paid, so an uncertain attempt is retried at most once."
  @spec paid?(declaration(), String.t()) :: boolean()
  def paid?(declaration, channel), do: channel in list(declaration, "paid_channels")

  # CH-6
  # TN-58
  @doc "Returns true when the provider processes data only in `country` (an ISO 3166-1 alpha-2 code), or inside the installation itself; a domestic-only tenant routes only to such providers."
  @spec domestic?(declaration(), String.t()) :: boolean()
  def domestic?(declaration, country) do
    case Map.get(declaration, "data_residency") do
      %{"in_installation" => true} -> true
      %{"processing_countries" => [_ | _] = countries} -> Enum.all?(countries, &(&1 == country))
      _missing -> false
    end
  end

  defp channels(declaration), do: list(declaration, "channels")

  defp list(map, key) do
    case Map.get(map, key) do
      rows when is_list(rows) -> rows
      _missing -> []
    end
  end

  defp unique?(rows, key) do
    keys = Enum.map(rows, key)
    length(keys) == length(Enum.uniq(keys))
  end

  defp error(message),
    do: {:error, Relay.Error.new(:invalid_package, message, %{dataset: "channel_event_evidence"})}
end
