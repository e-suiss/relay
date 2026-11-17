defmodule Relay.Agents.Protocols do
  @moduledoc """
  The protocol mapping layer (E-50, E-74, AG-46, AG-47, AG-72, L-28). Relay speaks A2A and MCP and carries AG-UI; its waitpoint model depends on none of them. What a protocol sees of a waitpoint is read from the `agent_protocols` data set: the versions Relay speaks and serves, and for each waitpoint state and interaction the task state of A2A, of the MCP tasks extension and of Anthropic Managed Agents. A protocol revision is a new version of that data set and changes nothing else.

  The translation loses nothing: a waitpoint state and its interaction always give one cell, and `waitpoints/3` gives back every waitpoint state and interaction a protocol state stands for. A cell is one of three rules. `:state` names the protocol state. `:unchanged` leaves the protocol's state as it is: a stalled waitpoint still waits. `:owner_decides` is the end of an expired or cancelled waitpoint, where Relay delivers the event and the owner of the task decides what the task becomes. The task itself belongs to the waiter; Relay never holds or advances it.
  """

  dir = Path.join([__DIR__, "..", "..", "..", "priv", "datasets", "agent_protocols"])
  paths = Path.wildcard(Path.join(dir, "v*.json"))
  for path <- paths, do: @external_resource(path)

  newest =
    Enum.max_by(paths, fn path ->
      path |> Path.basename(".json") |> String.trim_leading("v") |> String.to_integer()
    end)

  @bundled newest |> File.read!() |> Jason.decode!()
  @dataset "agent_protocols"
  @protocols %{a2a: "a2a", mcp_tasks: "mcp_tasks", managed_agents: "managed_agents"}
  @rules %{"state" => :state, "unchanged" => :unchanged, "owner_decides" => :owner_decides}
  @states ~w(open stalled resolved expired cancelled)
  @interactions ~w(response access_invitation event)

  @type table :: %{String.t() => term()}
  @type protocol :: :a2a | :mcp_tasks | :managed_agents
  @type interaction :: String.t()
  @type cell :: %{rule: :state | :unchanged | :owner_decides, state: String.t() | nil}

  # AG-47
  @doc "The name of the data set."
  @spec dataset() :: String.t()
  def dataset, do: @dataset

  # AG-47
  # AG-72
  @doc "The content of the newest bundled `agent_protocols` version."
  @spec bundled() :: table()
  def bundled, do: @bundled

  # E-50
  # E-74
  @doc "The version of `protocol` (`\"a2a\"` or `\"mcp\"`) Relay speaks when it sends."
  @spec current(table(), String.t()) :: String.t()
  def current(table \\ @bundled, protocol) when protocol in ["a2a", "mcp"],
    do: table["protocols"][protocol]["current"]

  # AG-72
  @doc "The versions of `protocol` Relay serves: the current one and the earlier ones still served beside it."
  @spec served(table(), String.t()) :: [String.t(), ...]
  def served(table \\ @bundled, protocol) when protocol in ["a2a", "mcp"],
    do: table["protocols"][protocol]["served"]

  # AG-72
  @doc "True when Relay serves `version` of `protocol`."
  @spec served?(table(), String.t(), term()) :: boolean()
  def served?(table \\ @bundled, protocol, version), do: version in served(table, protocol)

  # E-50
  @doc "The header that carries the version of `protocol`."
  @spec version_header(table(), String.t()) :: String.t()
  def version_header(table \\ @bundled, protocol) when protocol in ["a2a", "mcp"],
    do: table["protocols"][protocol]["version_header"]

  # AG-46
  @doc "The interaction of a waitpoint as the table reads it: `access_invitation` for an invitation to the Access approval surface, `response` for another question or review, `event` for an event waitpoint."
  @spec interaction(map()) :: interaction()
  def interaction(waitpoint) do
    kind = to_string(field(waitpoint, :kind))
    profile = field(waitpoint, :profile)

    cond do
      kind == "event" -> "event"
      profile in [:guardian_approval, "guardian_approval"] -> "access_invitation"
      true -> "response"
    end
  end

  defp field(waitpoint, key),
    do: Map.get(waitpoint, key) || Map.get(waitpoint, Atom.to_string(key))

  # AG-46
  # L-28
  @doc "What `protocol` sees of a waitpoint in `state` with `interaction`; `:error` for a state or an interaction the table does not know."
  @spec translate(table(), protocol(), String.t(), interaction()) :: {:ok, cell()} | :error
  def translate(table \\ @bundled, protocol, state, interaction)
      when is_map_key(@protocols, protocol) do
    case Enum.find(table["states"], &row?(&1, state, interaction)) do
      nil -> :error
      row -> {:ok, cell(row[Map.fetch!(@protocols, protocol)])}
    end
  end

  defp row?(%{"waitpoint" => state, "interaction" => of}, state, interaction)
       when interaction in @interactions,
       do: of in [interaction, "any"]

  defp row?(_row, _state, _interaction), do: false

  defp cell(%{"rule" => rule} = cell),
    do: %{rule: Map.fetch!(@rules, rule), state: Map.get(cell, "state")}

  # AG-46
  @doc "What `protocol` sees of a waitpoint, read from its `:state`, `:kind` and `:profile`."
  @spec of(table(), protocol(), map()) :: {:ok, cell()} | :error
  def of(table \\ @bundled, protocol, waitpoint),
    do: translate(table, protocol, to_string(field(waitpoint, :state)), interaction(waitpoint))

  # AG-46
  @doc "Every waitpoint state and interaction that `protocol_state` of `protocol` stands for, in the order of the table."
  @spec waitpoints(table(), protocol(), String.t()) :: [{String.t(), interaction()}]
  def waitpoints(table \\ @bundled, protocol, protocol_state)
      when is_map_key(@protocols, protocol) do
    for state <- @states,
        interaction <- @interactions,
        {:ok, %{rule: :state, state: ^protocol_state}} <-
          [translate(table, protocol, state, interaction)],
        do: {state, interaction}
  end

  # AG-46
  @doc "Checks what the JSON Schema of the data set cannot say: every waitpoint state and interaction has exactly one row, and a cell names a state exactly when its rule is `state`."
  @spec consistent(table()) :: :ok | {:error, Relay.Error.t()}
  def consistent(%{"states" => rows, "protocols" => protocols}) when is_list(rows) do
    cond do
      not Enum.all?(rows, &cells?/1) ->
        invalid("a cell names a state exactly when its rule is state")

      not Enum.all?(pairs(), &(matches(rows, &1) == 1)) ->
        invalid("every waitpoint state and interaction has exactly one row")

      not Enum.all?(["a2a", "mcp"], &(protocols[&1]["current"] in protocols[&1]["served"])) ->
        invalid("the current version of a protocol is served")

      true ->
        :ok
    end
  end

  def consistent(_content), do: invalid("the table has protocols and states")

  defp pairs, do: for(state <- @states, interaction <- @interactions, do: {state, interaction})

  defp matches(rows, {state, interaction}),
    do: Enum.count(rows, &row?(&1, state, interaction))

  defp cells?(row) do
    Enum.all?(Map.values(@protocols), fn protocol ->
      case row[protocol] do
        %{"rule" => "state"} = cell -> is_binary(cell["state"])
        %{"rule" => _other} = cell -> not is_map_key(cell, "state")
        _missing -> false
      end
    end)
  end

  defp invalid(message), do: {:error, Relay.Error.new(:validation_failed, message)}
end
