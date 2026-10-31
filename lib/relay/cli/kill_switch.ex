defmodule Relay.CLI.KillSwitch do
  @moduledoc """
  `relay kill-switch`: kill switches of the environment through the API.

  * `list` (`listKillSwitches`, `--include-released`) and `get <id>` (`getKillSwitch`).
  * `engage` (`engageKillSwitch`): `--scope`, `--ref`, `--reason` and `--ttl` (an ISO 8601 duration such as `PT2H`, or `none` for a record without TTL), with the optional `--channel`, `--message-class`, `--state`, `--canary-percent`, `--paused-until`, `--target`, `--target-ref` and `--ticket`.
  * `replace <id>` (`replaceKillSwitch`): `--state`, `--reason` and the optional `--ttl`, `--canary-percent` and `--paused-until`.
  * `release <id>` (`releaseKillSwitch`): `--reason`.

  An API client may engage only campaign and workflow kill switches and may only tighten them; other scopes, relaxing and releasing need an operator session in the console, and Relay's refusal (`auth_operator_session_required`) is reported as it is. In `live` every write needs confirmation.
  """

  @behaviour Relay.CLI.Command

  alias Relay.CLI.Args
  alias Relay.CLI.Client
  alias Relay.CLI.Confirm
  alias Relay.CLI.Failure

  @scopes ~w(tenant subtenant campaign workflow api_client sender)
  @states ~w(off canary paused_until)
  @targets ~w(all provider_account template)
  @path "/v1/kill_switches"

  # X-33
  @impl Relay.CLI.Command
  def run(ctx, %Args{sub: "list", opts: opts}) do
    params =
      for {key, value} <- [include_released: opts[:include_released], limit: opts[:limit]],
          value != nil,
          do: {key, value}

    case Client.list_all(ctx, ctx.config.environment, @path, params) do
      {:ok, records} -> {:ok, %{"kill_switches" => records}, Enum.map(records, &line/1)}
      {:error, _failure} = error -> error
    end
  end

  def run(ctx, %Args{sub: "get", positional: [id]}) do
    case Client.call(ctx, ctx.config.environment, :get, record_path(id)) do
      {:ok, %{body: %{} = record}} -> {:ok, record, [line(record)]}
      {:ok, _response} -> {:error, Client.unexpected_body()}
      {:error, _failure} = error -> error
    end
  end

  def run(ctx, %Args{sub: "engage", opts: opts}) do
    with {:ok, body} <- engage_body(opts) do
      write(ctx, "kill-switch engage stops #{body["scope_kind"]} work", @path, body)
    end
  end

  def run(ctx, %Args{sub: "replace", positional: [id], opts: opts}) do
    with {:ok, body} <- replace_body(opts) do
      write(ctx, "kill-switch replace changes #{id}", record_path(id) <> "/replace", body)
    end
  end

  def run(ctx, %Args{sub: "release", positional: [id], opts: opts}) do
    with {:ok, reason} <- required(opts, :reason) do
      body = %{"reason" => reason}
      write(ctx, "kill-switch release lifts #{id}", record_path(id) <> "/release", body)
    end
  end

  defp write(ctx, action, path, body) do
    environment = ctx.config.environment

    with :ok <- Confirm.live(ctx, environment, action),
         {:ok, response} <- Client.call(ctx, environment, :post, path, json: body) do
      {:ok, response.body, [line(response.body)]}
    end
  end

  defp engage_body(opts) do
    with {:ok, scope} <- one_of(opts, :scope, @scopes, true),
         {:ok, reason} <- required(opts, :reason),
         {:ok, ttl} <- ttl(opts, true),
         {:ok, state} <- one_of(opts, :state, @states, false),
         {:ok, target} <- one_of(opts, :target, @targets, false) do
      body =
        %{"scope_kind" => scope, "reason" => reason}
        |> Map.merge(ttl)
        |> put("scope_ref", opts[:ref])
        |> put("channel", opts[:channel])
        |> put("message_class", opts[:message_class])
        |> put("state", state)
        |> put("canary_percent", opts[:canary_percent])
        |> put("paused_until", opts[:paused_until])
        |> put("target_kind", target)
        |> put("target_ref", opts[:target_ref])
        |> put("ticket_ref", opts[:ticket])

      {:ok, body}
    end
  end

  defp replace_body(opts) do
    with {:ok, state} <- one_of(opts, :state, @states, true),
         {:ok, reason} <- required(opts, :reason),
         {:ok, ttl} <- ttl(opts, false) do
      body =
        %{"state" => state, "reason" => reason}
        |> Map.merge(ttl)
        |> put("canary_percent", opts[:canary_percent])
        |> put("paused_until", opts[:paused_until])

      {:ok, body}
    end
  end

  defp ttl(opts, required?) do
    case opts[:ttl] do
      nil when required? -> usage("--ttl is required: a duration such as PT2H, or none")
      nil -> {:ok, %{}}
      "none" -> {:ok, %{"no_ttl" => true}}
      ttl -> {:ok, %{"ttl" => ttl}}
    end
  end

  defp one_of(opts, key, allowed, required?) do
    option = "--" <> String.replace(Atom.to_string(key), "_", "-")
    choices = Enum.join(allowed, ", ")
    value = opts[key]

    cond do
      value in allowed -> {:ok, value}
      is_nil(value) and not required? -> {:ok, nil}
      is_nil(value) -> usage("#{option} is required: one of #{choices}")
      true -> usage("#{option} must be one of #{choices}")
    end
  end

  defp required(opts, key) do
    case opts[key] do
      value when is_binary(value) and value != "" -> {:ok, value}
      _missing -> usage("--#{key} is required")
    end
  end

  defp line(%{"id" => id} = record) do
    scope = Enum.join(Enum.reject([record["scope_kind"], record["scope_ref"]], &is_nil/1), ":")
    expires = if record["expires_at"], do: " expires #{record["expires_at"]}", else: ""
    "#{id} #{record["status"]} #{scope} state=#{record["state"]}#{expires}"
  end

  defp line(other), do: inspect(other)

  defp record_path(id), do: @path <> "/" <> Client.segment(id)

  defp put(map, _key, nil), do: map
  defp put(map, key, value), do: Map.put(map, key, value)

  defp usage(message), do: {:error, Failure.new(:usage, "usage_error", message)}
end
