defmodule Relay.CLI.Args do
  @moduledoc """
  Argument parsing of the command line tool. Options are strict: an unknown command, an unknown option or a missing or extra argument is a usage error.
  """

  @enforce_keys [:command]
  defstruct [:command, :sub, positional: [], opts: [], json?: false, yes?: false]

  @type t :: %__MODULE__{
          command: String.t(),
          sub: String.t() | nil,
          positional: [String.t()],
          opts: keyword(),
          json?: boolean(),
          yes?: boolean()
        }

  @global [
    json: :boolean,
    env: :string,
    api_url: :string,
    issuer: :string,
    client_id: :string,
    client_secret_file: :string,
    scope: :string,
    profile: :string,
    config: :string,
    api_version: :string,
    yes: :boolean,
    confirm_live: :boolean,
    help: :boolean
  ]
  @aliases [y: :yes, h: :help]

  @event [to: :keep, recipient: :keep, data: :string, data_file: :string, dedup_key: :string]
  @filters [workflow: :string, subscriber: :string, status: :string, interval: :integer]
  @preview [
    template: :string,
    steps: :boolean,
    channel: :keep,
    locale: :string,
    version: :string,
    sample: :string
  ]

  @logs [
    limit: :integer,
    follow: :boolean,
    deliveries: :boolean,
    since: :string,
    until: :string,
    why: :boolean
  ]

  @push [publish: :boolean, note: :string, accept_warnings: :boolean, manage_as_code: :boolean]

  @commands %{
    "trigger" => {@event, 1, 1},
    "preview" => {@event ++ @preview, 1, 1},
    "pull" => {[dir: :string, kind: :keep, format: :string], 0, :many},
    "push" => {@push ++ [dir: :string, kind: :keep], 0, :many},
    "promote" => {@push ++ [kind: :string, all: :boolean, version: :integer], 0, :many},
    "logs" => {@filters ++ @logs, 0, 0},
    "listen" => {@filters ++ [forward_to: :string], 0, 0}
  }

  @engage [
    scope: :string,
    ref: :string,
    reason: :string,
    ttl: :string,
    channel: :string,
    message_class: :string,
    state: :string,
    canary_percent: :integer,
    paused_until: :string,
    target: :string,
    target_ref: :string,
    ticket: :string
  ]
  @replace [
    state: :string,
    reason: :string,
    ttl: :string,
    canary_percent: :integer,
    paused_until: :string
  ]

  @kill_switch %{
    "list" => {[include_released: :boolean, limit: :integer], 0, 0},
    "get" => {[], 1, 1},
    "engage" => {@engage, 0, 0},
    "replace" => {@replace, 1, 1},
    "release" => {[reason: :string], 1, 1}
  }

  @usage """
  Usage: relay <command> [arguments] [options]

  Commands:
    trigger <workflow>          Send an event to a workflow
    preview <workflow>          Dry-run an event in the test environment; with --template
                                render a template, with --steps preview the workflow steps
    pull [key...]               Write the route, template and workflow definitions of the
                                environment to files under --dir (default relay)
    push [file...]              Write definition files back as drafts; --publish publishes them
    promote <key...> | --all    Publish definitions of test in live (--kind, --version)
    logs                        Show recent notifications (--follow, --deliveries, --limit,
                                --since, --until); --why --subscriber <id> explains why
                                a subscriber did or did not get them
    listen --forward-to <url>   Forward new notifications to a local URL
    kill-switch list            List kill switches (--include-released)
    kill-switch get <id>        Show a kill switch
    kill-switch engage          Engage a kill switch (--scope, --ref, --reason, --ttl)
    kill-switch replace <id>    Tighten a kill switch (--state, --reason, --ttl)
    kill-switch release <id>    Release a kill switch (--reason)
    help                        Show this help

  Event options (trigger, preview):
    --to <id>                   Recipient external id; repeatable
    --recipient <json>          Recipient object such as {"id":"u-1","email":"a@example.com"}
    --data <json>, --data-file <path>   Event data object
    --dedup-key <key>           Business deduplication key

  Preview options: --template <key>, --steps, --channel <channel> (repeatable),
  --locale <tag>, --version draft|live|<n>, --sample schema_examples|masked_recent|boundary

  Definition options (pull, push, promote):
    --dir <path>                Directory of routes/, templates/ and workflows/ (default relay)
    --kind route|template|workflow   Only this kind; repeatable for pull and push,
                                one kind for promote (default workflow)
    --format json|yaml          Format of new files written by pull (default json)
    --publish                   push: publish each written draft
    --note <text>               Publication note
    --accept-warnings           Publish templates despite warning findings
    --manage-as-code            Make code the single manager of a panel-managed workflow
    --all                       promote: every published definition of test
    --version <n>               promote: this version of one template or workflow

  Filters (logs, listen): --workflow <key>, --subscriber <id>, --status <status>,
  --interval <seconds> (polling interval, default 2)

  Global options:
    --env test|live             Environment of the API client (RELAY_ENVIRONMENT)
    --api-url <url>             Relay API base URL (RELAY_API_URL)
    --issuer <url>              Access issuer URL (RELAY_ACCESS_ISSUER)
    --client-id <id>            API client id (RELAY_CLIENT_ID)
    --client-secret-file <path> File holding the client secret (RELAY_CLIENT_SECRET_FILE)
    --scope <scopes>            Scopes to request from Access (RELAY_SCOPE)
    --api-version <date>        Relay-Version to send (RELAY_API_VERSION)
    --profile <name>            Profile of the configuration file (RELAY_PROFILE)
    --config <path>             Configuration file (RELAY_CONFIG)
    --json                      Print JSON; the output always carries exit_code
    --yes, --confirm-live       Confirm a change to the live environment

  Exit codes: 0 success, 1 unexpected error, 2 usage error, 3 authentication or
  authorization, 4 not found, 5 validation or conflict, 6 rate limit or quota,
  7 server or connection, 8 live change not confirmed.
  """

  # X-33
  @doc "The usage text."
  @spec usage() :: String.t()
  def usage, do: @usage

  # X-33
  # X-42
  @doc "Parses a command line into a command, its arguments and options; help requests return the usage text."
  @spec parse([String.t()]) :: {:ok, t()} | {:help, String.t()} | {:error, String.t(), boolean()}
  def parse(argv) when is_list(argv) do
    json? = "--json" in argv

    case OptionParser.parse_head(argv, strict: @global, aliases: @aliases) do
      {_opts, _rest, [_ | _] = invalid} -> {:error, invalid_message(invalid), json?}
      {opts, [], []} -> if opts[:help], do: {:help, @usage}, else: {:error, "no command", json?}
      {_opts, ["help" | _rest], []} -> {:help, @usage}
      {head, [name | tail], []} -> command(name, tail, head, json?)
    end
  end

  @doc "The name of the command, with the kill switch action, as shown in output."
  @spec label(t()) :: String.t()
  def label(%__MODULE__{sub: nil, command: command}), do: command
  def label(%__MODULE__{sub: sub, command: command}), do: command <> " " <> sub

  defp command("kill-switch", tail, head, json?) do
    with [sub | rest] <- tail,
         {:ok, spec} <- Map.fetch(@kill_switch, sub) do
      build("kill-switch", sub, spec, rest, head, json?)
    else
      _other ->
        if head[:help] || "--help" in tail || "-h" in tail,
          do: {:help, @usage},
          else: {:error, "kill-switch needs one of: list, get, engage, replace, release", json?}
    end
  end

  defp command(name, tail, head, json?) do
    case Map.fetch(@commands, name) do
      {:ok, spec} -> build(name, nil, spec, tail, head, json?)
      :error -> {:error, "unknown command " <> name, json?}
    end
  end

  defp build(name, sub, {switches, min, max}, tail, head, json?) do
    case OptionParser.parse(tail, strict: @global ++ switches, aliases: @aliases) do
      {_opts, _positional, [_ | _] = invalid} ->
        {:error, invalid_message(invalid), json?}

      {opts, positional, []} ->
        opts = Keyword.merge(head, opts)
        args = %__MODULE__{command: name, sub: sub, positional: positional, opts: opts}

        cond do
          opts[:help] ->
            {:help, @usage}

          not arity?(length(positional), min, max) ->
            {:error, arity_message(args, min, max), json?}

          true ->
            {:ok, %{args | json?: opts[:json] == true, yes?: yes?(opts)}}
        end
    end
  end

  defp arity?(count, min, :many), do: count >= min
  defp arity?(count, min, max), do: count >= min and count <= max

  defp arity_message(args, 0, 0), do: label(args) <> " takes no arguments"
  defp arity_message(args, 1, 1), do: label(args) <> " takes exactly one argument"
  defp arity_message(args, _min, _max), do: label(args) <> " got unexpected arguments"

  defp yes?(opts), do: opts[:yes] == true or opts[:confirm_live] == true

  defp invalid_message([{option, nil} | _rest]), do: "unknown option or missing value: " <> option
  defp invalid_message([{option, _value} | _rest]), do: "invalid value for " <> option
end
