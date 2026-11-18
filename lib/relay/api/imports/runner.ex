defmodule Relay.Api.Imports.Runner do
  @moduledoc """
  Writes the lines of an import through the contexts' own write paths (OP-96, OP-55, OP-97) and builds its report (`Relay.Api.Imports.Report`). Every write is idempotent, so a job that runs again after a failure writes nothing twice.

  * `suppressions`: each address is suppressed on its channel (`invalid` stays `invalid`, any other reason is a manual suppression).
  * `consents`: the lines of a subscriber and channel are folded asymmetrically (`Relay.Api.Imports.Lines.fold_consent/1`); a refusal is recorded `revoked`; a grant is recorded `active` only when it carries its evidence and, for a commercial message to a Turkish address, the local İYS copy holds it; anything else is recorded `none` with the source `imported_unknown`.
  * `subscribers`: lines of the same external id are merged in line order; lines that give the same address under different external ids, or an address an existing subscriber holds, are reported and not merged; a subscriber whose digest window is still open in the legacy system is skipped; then the imported addresses are checked against the suppression list and counted.
  * `devices`: dead tokens are dropped, the newest line of a `(token, platform)` pair stays, a device without an external id belongs to an anonymous subscriber, and the source's last seen time (or none) is kept with the time of the migration.
  * `templates`: converted (`Relay.Templates.convert/3`), nothing is written.
  * `scheduled`: each send is accepted through the path of `POST /v1/events` with an idempotency key of its legacy reference and confirmed with its event id.
  """

  alias Relay.Api.ErrorCatalog
  alias Relay.Api.Events
  alias Relay.Api.Idempotency
  alias Relay.Api.Imports.Lines
  alias Relay.Api.Imports.Report
  alias Relay.Api.Imports.Store

  @suppression_channels ~w(email sms voice whatsapp)
  @phone_channels ~w(sms voice whatsapp)
  @consent_channels ~w(push web_push email sms voice whatsapp in_app)
  @consent_statuses ~w(granted refused unknown)
  @consent_kinds ~w(explicit_opt_in soft_opt_in legitimate_interest)
  @recipient_types ~w(individual merchant)
  @platforms ~w(apns fcm hms web_push unified_push)
  @permissions ~w(granted denied provisional not_determined)
  @app ~r/\A[A-Za-z0-9._:\/-]{1,256}\z/
  @external_id ~r/\A[\x21-\x7E]{1,256}\z/
  @legacy_ref ~r/\A[\x21-\x7E]{1,200}\z/
  @path ~r/\A[A-Za-z_][A-Za-z0-9_-]*(\.[A-Za-z_][A-Za-z0-9_-]*)*\z/
  @subscriber_keys ~w(external_id email phone name locale timezone country attributes provider_ref
                      digest_open_until)
  @profile_keys ~w(email phone name locale timezone country attributes)
  @alias_max_s 90 * 86_400
  @endpoint "IMPORT"

  @type outcome :: {:ok, Report.t()} | {:error, term()}

  # OP-96
  # OP-55
  # OP-97
  @doc "Writes the lines of a pending import row of `kind` and answers its report; `{:error, reason}` when a store was unavailable, so the job runs again."
  @spec run(Relay.Scope.t(), map(), [Lines.line()]) :: outcome()
  def run(scope, import, lines) do
    {:ok, actor} = Relay.Actor.new(:system, "relay:import", "relay")
    ctx = %{scope: scope, import: import, actor: actor, now: Relay.Clock.utc_now()}
    report = Report.new(length(lines))

    {report, valid} =
      Enum.reduce(lines, {report, []}, fn
        {line, {:ok, row}}, {acc, rows} -> {acc, rows ++ [{line, row}]}
        {line, {:invalid, code}}, {acc, rows} -> {Report.invalid(acc, line, code), rows}
      end)

    kind(import["kind"], ctx, valid, report)
  end

  defp kind("suppressions", ctx, rows, report), do: each(rows, report, &suppression(ctx, &1, &2))

  defp kind("consents", ctx, rows, report), do: consents(ctx, rows, report)
  defp kind("subscribers", ctx, rows, report), do: subscribers(ctx, rows, report)
  defp kind("devices", ctx, rows, report), do: devices(ctx, rows, report)
  defp kind("templates", ctx, rows, report), do: templates(ctx, rows, report)
  defp kind("scheduled", ctx, rows, report), do: scheduled(ctx, rows, report)

  defp each(rows, report, fun) do
    Enum.reduce_while(rows, {:ok, report}, fn row, {:ok, acc} ->
      case fun.(row, acc) do
        {:ok, acc} -> {:cont, {:ok, acc}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp apply_outcome(report, line, outcome) do
    case outcome do
      {:written, record} -> {:ok, Report.written(report, record)}
      {:unchanged, record} -> {:ok, Report.unchanged(report, record)}
      {:invalid, code} -> {:ok, Report.invalid(report, line, code)}
      {:skipped, code} -> {:ok, Report.skipped(report, line, code)}
      {:retry, reason} -> {:error, reason}
    end
  end

  defp suppression(ctx, {line, row}, report) do
    outcome =
      with :ok <- keys(row, ~w(channel address reason country)),
           {:ok, channel} <- member(row["channel"], @suppression_channels, "channel_invalid"),
           {:ok, address} <- address(channel, row["address"], row["country"]),
           reason = if(row["reason"] == "invalid", do: "invalid", else: "manual"),
           body = %{"channel" => channel, "address" => address, "reason" => reason},
           {:ok, prepared} <- error(Relay.Api.Suppressions.prepare(ctx.scope, body)) do
        added(ctx, line, prepared)
      end

    apply_outcome(report, line, outcome)
  end

  defp added(ctx, line, prepared) do
    write = fn _status -> Relay.Preferences.add_suppression(ctx.scope, prepared, ctx.actor) end

    case Store.in_scope(ctx.scope, write) do
      {:ok, {:added, id}} -> {:written, record(line, "suppression", id)}
      {:ok, {:exists, id}} -> {:unchanged, record(line, "suppression", id)}
      {:ok, {other, _id}} -> {:invalid, Atom.to_string(other)}
      {:error, reason} -> {:retry, reason}
    end
  end

  defp address("email", address, _country) when is_binary(address) do
    case Relay.Email.new(address) do
      {:ok, _redacted} -> {:ok, String.trim(address)}
      {:error, _error} -> {:invalid, "email_invalid"}
    end
  end

  defp address(channel, address, country) when channel in @phone_channels do
    case Lines.phone(address, country) do
      {:ok, phone} -> {:ok, phone}
      :error -> {:invalid, "phone_not_e164"}
    end
  end

  defp address(_channel, _address, _country), do: {:invalid, "address_invalid"}

  defp consents(ctx, rows, report) do
    keys = ~w(external_id channel status address country commercial occurred_at consent_kind
              recipient_type text_version evidence)

    {report, groups} =
      Enum.reduce(rows, {report, %{}}, fn {line, row}, {acc, groups} ->
        case consent_key(row, keys) do
          {:ok, key} -> {acc, Map.update(groups, key, [{line, row}], &(&1 ++ [{line, row}]))}
          {:invalid, code} -> {Report.invalid(acc, line, code), groups}
        end
      end)

    counts = %{"refused" => 0, "granted" => 0, "iys_verified" => 0, "imported_unknown" => 0}
    ordered = Enum.sort_by(groups, fn {_key, group} -> group |> List.last() |> elem(0) end)

    result =
      Enum.reduce_while(ordered, {:ok, {report, counts}}, fn {key, group}, {:ok, acc} ->
        case consent(ctx, key, group, acc) do
          {:ok, acc} -> {:cont, {:ok, acc}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)

    case result do
      {:ok, {report, counts}} -> {:ok, Report.section(report, :consents, counts)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp consent_key(row, keys) do
    with :ok <- keys(row, keys),
         {:ok, external_id} <- external_id(row["external_id"]),
         {:ok, channel} <- member(row["channel"], @consent_channels, "channel_invalid"),
         {:ok, _status} <- member(row["status"], @consent_statuses, "status_invalid") do
      {:ok, {external_id, channel}}
    end
  end

  defp consent(ctx, {external_id, channel}, group, {report, counts}) do
    statuses = Enum.map(group, fn {line, row} -> {line, row["status"]} end)
    {line, _row} = List.last(group)
    lines = Enum.map(group, &elem(&1, 0))

    {decision, line} =
      case Lines.fold_consent(statuses) do
        :refused -> {:refused, line}
        :unknown -> {:unknown, line}
        {:granted, grant_line} -> {verify(ctx, channel, find(group, grant_line)), grant_line}
      end

    report = Enum.reduce(lines -- [line], report, &Report.skipped(&2, &1, "folded_consent"))

    outcome =
      case subscriber(ctx, external_id, %{}) do
        {:ok, _result, recipient_id} ->
          record_consent(ctx, recipient_id, channel, decision, line, find(group, line))

        other ->
          other
      end

    with {:ok, report} <- apply_outcome(report, line, outcome),
         do: {:ok, {report, Map.update!(counts, label(decision), &(&1 + 1))}}
  end

  defp find(group, line), do: group |> Enum.find(&(elem(&1, 0) == line)) |> elem(1)

  defp label(:refused), do: "refused"
  defp label({:granted, :iys}), do: "iys_verified"
  defp label({:granted, :evidence}), do: "granted"
  defp label(:unknown), do: "imported_unknown"

  defp verify(ctx, channel, row) do
    cond do
      not evidence?(row) -> :unknown
      row["commercial"] == false -> {:granted, :evidence}
      true -> iys(ctx, channel, row)
    end
  end

  defp evidence?(row) do
    is_binary(row["text_version"]) and row["text_version"] != "" and is_map(row["evidence"]) and
      row["consent_kind"] in @consent_kinds and row["recipient_type"] in @recipient_types and
      match?({:ok, _at}, Lines.parse_time(row["occurred_at"]))
  end

  defp iys(_ctx, channel, _row) when channel not in ["email" | @phone_channels],
    do: {:granted, :evidence}

  defp iys(ctx, channel, row) do
    kind = if channel == "email", do: "email", else: "phone"

    with {:ok, address} <- iys_address(channel, row),
         {:ok, [{_key_id, digest} | _rest]} <-
           Relay.Subscribers.address_digests(ctx.scope, kind, address),
         {:ok, status} <-
           Store.in_scope(ctx.scope, fn _status ->
             Relay.Iys.permission(ctx.scope, nil, channel, digest)
           end) do
      case status do
        :out_of_scope -> {:granted, :evidence}
        {:cached, :approved, _synced} -> {:granted, :iys}
        {:cached, :rejected, _synced} -> :refused
        _none_or_not_configured -> :unknown
      end
    else
      _other -> :unknown
    end
  end

  defp iys_address("email", row), do: address("email", row["address"], nil)

  defp iys_address(channel, row) when channel in @phone_channels,
    do: address(channel, row["address"], row["country"])

  defp record_consent(ctx, recipient_id, channel, decision, line, row) do
    occurred_at =
      case Lines.parse_time(row["occurred_at"]) do
        {:ok, at} -> at
        :error -> ctx.import["created_at"]
      end

    attrs =
      Map.merge(
        %{
          recipient_id: recipient_id,
          brand_subtenant_id: nil,
          channel: channel,
          consent_kind: nil,
          recipient_type: nil,
          sequence: DateTime.to_unix(ctx.import["created_at"], :microsecond),
          occurred_at: occurred_at,
          text_version_digest: nil,
          evidence: nil,
          iys_transaction_ref: nil,
          writer: "relay",
          source_event_ref: "import:#{Relay.Id.to_string(ctx.import["id"])}:#{line}"
        },
        consent_status(decision, row)
      )

    case Relay.Preferences.record_consent_entry(ctx.scope, attrs) do
      {:ok, {:recorded, id}} ->
        {:written, record(line, "consent", id, recipient_id)}

      {:ok, {result, id}} when result in [:duplicate, :stale] ->
        {:unchanged, record(line, "consent", id, recipient_id)}

      {:ok, {other, _id}} ->
        {:invalid, Atom.to_string(other)}

      {:error, reason} ->
        error({:error, reason})
    end
  end

  defp consent_status(:refused, _row), do: %{status: "revoked", source: "import"}
  defp consent_status(:unknown, _row), do: %{status: "none", source: "imported_unknown"}

  defp consent_status({:granted, _basis}, row) do
    %{
      status: "active",
      source: "import",
      consent_kind: row["consent_kind"],
      recipient_type: row["recipient_type"],
      text_version_digest: :crypto.hash(:sha256, row["text_version"]),
      evidence: row["evidence"]
    }
  end

  defp subscribers(ctx, rows, report) do
    {report, kept} =
      Enum.reduce(rows, {report, []}, fn {line, row}, {acc, kept} ->
        case profile(ctx, row) do
          {:ok, external_id, fields} -> {acc, kept ++ [{line, external_id, fields, row}]}
          {:skipped, code} -> {Report.skipped(acc, line, code), kept}
          {:invalid, code} -> {Report.invalid(acc, line, code), kept}
        end
      end)

    {report, merged} = merge(kept, report)
    report = file_conflicts(merged, report)

    with {:ok, {report, addresses}} <- write_subscribers(ctx, merged, report),
         {:ok, check} <- suppression_check(ctx, addresses) do
      {:ok, Report.section(report, :suppression_check, check)}
    end
  end

  defp profile(ctx, row) do
    with :ok <- keys(row, @subscriber_keys),
         {:ok, external_id} <- external_id(row["external_id"]),
         :ok <- digest_window(ctx, row["digest_open_until"]),
         {:ok, fields} <- fields(Map.take(row, @profile_keys)) do
      {:ok, external_id, fields}
    end
  end

  defp digest_window(_ctx, nil), do: :ok

  defp digest_window(ctx, text) do
    case Lines.parse_time(text) do
      {:ok, until} ->
        if DateTime.compare(until, ctx.now) == :gt,
          do: {:skipped, "digest_window_open"},
          else: :ok

      :error ->
        {:invalid, "digest_open_until_invalid"}
    end
  end

  defp fields(fields) do
    Enum.reduce_while(fields, {:ok, %{}}, fn {name, value}, {:ok, acc} ->
      case field(name, value, fields["country"]) do
        {:ok, value} -> {:cont, {:ok, Map.put(acc, name, value)}}
        {:invalid, code} -> {:halt, {:invalid, code}}
      end
    end)
  end

  defp field(_name, nil, _country), do: {:ok, nil}

  defp field("email", value, _country), do: address("email", value, nil)

  defp field("phone", value, country) do
    case Lines.phone(value, country) do
      {:ok, phone} -> {:ok, phone}
      :error -> {:invalid, "phone_not_e164"}
    end
  end

  defp field("locale", value, _country) do
    case Lines.locale(value) do
      {:ok, tag} -> {:ok, tag}
      :error -> {:invalid, "locale_invalid"}
    end
  end

  defp field(_name, value, _country), do: {:ok, value}

  defp merge(kept, report) do
    groups = Enum.group_by(kept, &elem(&1, 1))

    merged =
      groups
      |> Enum.map(fn {external_id, group} ->
        {line, _external_id, _fields, row} = List.last(group)
        fields = group |> Enum.map(&elem(&1, 2)) |> Enum.reduce(%{}, &Map.merge(&2, &1))
        {line, external_id, fields, row}
      end)
      |> Enum.sort_by(&elem(&1, 0))

    report =
      groups
      |> Enum.flat_map(fn {_id, group} -> group |> Enum.drop(-1) |> Enum.map(&elem(&1, 0)) end)
      |> Enum.reduce(report, &Report.skipped(&2, &1, "merged_same_external_id"))

    {report, merged}
  end

  defp file_conflicts(merged, report) do
    Enum.reduce(["email", "phone"], report, fn field, acc ->
      merged
      |> Enum.map(fn {line, external_id, fields, _row} -> {line, external_id, fields[field]} end)
      |> Lines.conflicts()
      |> Enum.reduce(acc, &Report.conflict(&2, field, &1))
    end)
  end

  defp write_subscribers(ctx, merged, report) do
    Enum.reduce_while(merged, {:ok, {report, []}}, fn entry, {:ok, {acc, addresses}} ->
      case write_subscriber(ctx, entry, acc) do
        {:ok, acc, more} -> {:cont, {:ok, {acc, addresses ++ more}}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp write_subscriber(ctx, {line, external_id, fields, row}, report) do
    report = existing_conflicts(ctx, line, external_id, fields, report)

    with {:ok, result, recipient_id} <- subscriber(ctx, external_id, fields),
         {:ok, ref} <- provider_ref(ctx, recipient_id, row["provider_ref"]) do
      record = {line, "subscriber", Relay.Id.to_string(recipient_id), recipient_id, ref, nil}

      report =
        if result == :unchanged,
          do: Report.unchanged(report, record),
          else: Report.written(report, record)

      {:ok, report, addresses(line, fields)}
    else
      other -> with {:ok, report} <- apply_outcome(report, line, other), do: {:ok, report, []}
    end
  end

  defp addresses(line, fields) do
    for {field, kind} <- [{"email", "email"}, {"phone", "phone"}],
        is_binary(fields[field]),
        do: {line, kind, fields[field]}
  end

  defp existing_conflicts(ctx, line, external_id, fields, report) do
    Enum.reduce(["email", "phone"], report, fn field, acc ->
      with address when is_binary(address) <- fields[field],
           {:ok, {found, _more}} <- Relay.Subscribers.lookup(ctx.scope, field, address, 5),
           true <- Enum.any?(found, &(&1["external_id"] != external_id)) do
        Report.conflict(acc, field, [0, line])
      else
        _none -> acc
      end
    end)
  end

  defp suppression_check(_ctx, []),
    do: {:ok, %{"addresses" => 0, "suppressed" => 0, "expected" => 0, "verified" => true}}

  defp suppression_check(ctx, addresses) do
    numbered = Enum.with_index(addresses)

    entries =
      Enum.reduce_while(numbered, {:ok, []}, fn {{_line, kind, address}, n}, {:ok, acc} ->
        case Relay.Subscribers.address_digests(ctx.scope, kind, address) do
          {:ok, digests} -> {:cont, {:ok, acc ++ for({_key, d} <- digests, do: {n, kind, d})}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)

    batch = ctx.import["batch"]

    with {:ok, entries} <- entries,
         count = fn _status -> Store.suppression_counts(entries, batch) end,
         {:ok, counts} <- Store.in_scope(ctx.scope, count) do
      {:ok,
       %{
         "addresses" => length(addresses),
         "suppressed" => counts.suppressed,
         "expected" => counts.expected,
         "verified" => counts.expected_suppressed == counts.expected
       }}
    end
  end

  defp devices(ctx, rows, report) do
    keys = ~w(external_id platform token app apns_environment permission locale timezone
              last_seen_at state provider_ref)

    {report, valid} =
      Enum.reduce(rows, {report, []}, fn {line, row}, {acc, valid} ->
        case device_row(row, keys) do
          {:ok, row} -> {acc, valid ++ [{line, row}]}
          {:invalid, code} -> {Report.invalid(acc, line, code), valid}
        end
      end)

    {kept, dead, older} = Lines.select_devices(valid)
    report = Enum.reduce(dead, report, &Report.skipped(&2, &1, "dead_token"))
    report = Enum.reduce(older, report, &Report.skipped(&2, &1, "older_duplicate_token"))

    section = %{
      "dead_dropped" => length(dead),
      "older_duplicates_dropped" => length(older),
      "anonymous_subscribers" => 0,
      "last_seen_missing" => 0
    }

    result =
      Enum.reduce_while(kept, {:ok, {report, section}}, fn {line, row}, {:ok, {acc, section}} ->
        case device(ctx, line, row, acc, section) do
          {:ok, acc, section} -> {:cont, {:ok, {acc, section}}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)

    case result do
      {:ok, {report, section}} -> {:ok, Report.section(report, :devices, section)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp device_row(row, keys) do
    permission = row["permission"] || "not_determined"

    with :ok <- keys(row, keys),
         {:ok, _platform} <- member(row["platform"], @platforms, "platform_invalid"),
         :ok <- check(is_binary(row["token"]) and row["token"] != "", "token_invalid"),
         :ok <- check(is_binary(row["app"]) and Regex.match?(@app, row["app"]), "app_invalid"),
         {:ok, permission} <- member(permission, @permissions, "permission_invalid"),
         {:ok, locale} <- optional_locale(row["locale"]) do
      {:ok, Map.merge(row, %{"permission" => permission, "locale" => locale})}
    end
  end

  defp check(true, _code), do: :ok
  defp check(false, code), do: {:invalid, code}

  defp optional_locale(nil), do: {:ok, nil}

  defp optional_locale(text) do
    case Lines.locale(text) do
      {:ok, tag} -> {:ok, tag}
      :error -> {:invalid, "locale_invalid"}
    end
  end

  defp device(ctx, line, row, report, section) do
    {external_id, anonymous} =
      case row["external_id"] do
        id when is_binary(id) -> {id, 0}
        _none -> {anonymous_id(row), 1}
      end

    last_seen =
      case Lines.parse_time(row["last_seen_at"]) do
        {:ok, at} -> at
        :error -> nil
      end

    section = %{
      section
      | "anonymous_subscribers" => section["anonymous_subscribers"] + anonymous,
        "last_seen_missing" => section["last_seen_missing"] + if(last_seen, do: 0, else: 1)
    }

    outcome =
      with {:ok, external_id} <- external_id(external_id),
           {:ok, _result, recipient_id} <- subscriber(ctx, external_id, %{}),
           body = registration(row),
           {:ok, plan} <- error(Relay.Devices.prepare(ctx.scope, recipient_id, body)),
           {:ok, ref} <- provider_ref(ctx, recipient_id, row["provider_ref"]) do
        register(ctx, line, plan, recipient_id, ref, last_seen)
      end

    with {:ok, report} <- apply_outcome(report, line, outcome), do: {:ok, report, section}
  end

  defp registration(row),
    do: Map.take(row, ~w(platform token app apns_environment permission locale timezone))

  defp anonymous_id(row) do
    digest = :crypto.hash(:sha256, [row["platform"], ":", row["token"]])
    "anon_" <> Base.encode16(binary_part(digest, 0, 16), case: :lower)
  end

  defp register(ctx, line, plan, recipient_id, ref, last_seen) do
    case Store.in_scope(ctx.scope, fn _status -> Relay.Devices.register(plan) end) do
      {:ok, {result, id}} when result in [:created, :reassigned, :updated] ->
        {:written, {line, "device", Relay.Id.to_string(id), recipient_id, ref, last_seen}}

      {:ok, {other, _id}} ->
        {:invalid, Atom.to_string(other)}

      {:error, reason} ->
        {:retry, reason}
    end
  end

  defp templates(ctx, rows, report) do
    {report, results} =
      Enum.reduce(rows, {report, []}, fn {line, row}, {acc, results} ->
        case template(ctx, line, row) do
          {:ok, result} -> {Report.written(acc, nil), results ++ [result]}
          {:invalid, code} -> {Report.invalid(acc, line, code), results}
        end
      end)

    {:ok, Report.section(report, :templates, results)}
  end

  defp template(ctx, line, row) do
    key = row["key"]

    with :ok <- keys(row, ~w(key language source aliases aliases_expire_at)),
         :ok <- check(is_binary(key) and String.length(key) in 1..128, "key_invalid"),
         {:ok, language} <- language(row["language"]),
         :ok <- check(is_binary(row["source"]), "source_invalid"),
         {:ok, aliases, expires_at} <- aliases(ctx, row["aliases"], row["aliases_expire_at"]) do
      result = Relay.Templates.convert(language, row["source"], aliases)

      {:ok,
       %{
         "line" => line,
         "key" => key,
         "language" => row["language"],
         "status" => result.status,
         "output" => result.output,
         "findings" => Enum.map(result.findings, &finding_view/1),
         "aliases" => Enum.map(result.aliases, &alias_view(&1, aliases, expires_at))
       }}
    end
  end

  defp language("liquid"), do: {:ok, :liquid}
  defp language("handlebars"), do: {:ok, :handlebars}
  defp language(_other), do: {:invalid, "language_invalid"}

  defp finding_view(f), do: %{"code" => f.code, "line" => f.line, "detail" => f.detail}

  defp alias_view(name, aliases, expires_at),
    do: %{"name" => name, "target" => aliases[name], "expires_at" => expires_at}

  defp aliases(_ctx, nil, _expires), do: {:ok, %{}, nil}

  defp aliases(ctx, aliases, expires) when is_map(aliases) and map_size(aliases) <= 100 do
    valid? =
      Enum.all?(aliases, fn {name, target} ->
        is_binary(target) and Regex.match?(@path, name) and Regex.match?(@path, target)
      end)

    with :ok <- check(valid?, "aliases_invalid"),
         {:ok, at} <- alias_expiry(ctx, expires) do
      {:ok, aliases, at}
    end
  end

  defp aliases(_ctx, _aliases, _expires), do: {:invalid, "aliases_invalid"}

  defp alias_expiry(ctx, text) do
    with {:ok, at} <- Lines.parse_time(text),
         seconds = DateTime.diff(at, ctx.now, :second),
         true <- seconds > 0 and seconds <= @alias_max_s do
      {:ok, at}
    else
      _other -> {:invalid, "alias_expiry_invalid"}
    end
  end

  defp scheduled(ctx, rows, report) do
    result =
      Enum.reduce_while(rows, {:ok, {report, []}}, fn {line, row}, {:ok, acc} ->
        case scheduled_line(ctx, line, row, acc) do
          {:ok, acc} -> {:cont, {:ok, acc}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)

    case result do
      {:ok, {report, confirmations}} ->
        {:ok, Report.section(report, :confirmations, confirmations)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp scheduled_line(ctx, line, row, {report, confirmations}) do
    case schedule(ctx, line, row) do
      {:confirmed, :fresh, confirmation, record} ->
        {:ok, {Report.written(report, record), confirmations ++ [confirmation]}}

      {:confirmed, _replayed, confirmation, record} ->
        {:ok, {Report.unchanged(report, record), confirmations ++ [confirmation]}}

      other ->
        with {:ok, report} <- apply_outcome(report, line, other),
             do: {:ok, {report, confirmations}}
    end
  end

  defp schedule(ctx, line, row) do
    legacy_ref = row["legacy_ref"]
    keys = ~w(legacy_ref workflow subscriber_id data send_at digest_open_until)

    with :ok <- keys(row, keys),
         :ok <- check(legacy_ref?(legacy_ref), "legacy_ref_invalid"),
         :ok <- digest_window(ctx, row["digest_open_until"]),
         body = event_body(row),
         :ok <- schema(body) do
      accept(ctx, line, row["legacy_ref"], body)
    end
  end

  defp legacy_ref?(ref), do: is_binary(ref) and Regex.match?(@legacy_ref, ref)

  defp event_body(row) do
    %{
      "workflow" => row["workflow"],
      "to" => [row["subscriber_id"]],
      "data" => row["data"] || %{},
      "send_at" => row["send_at"]
    }
  end

  defp schema(body) do
    case Relay.Api.Schema.validate_request("createEvent", "application/json", body) do
      :ok -> :ok
      {:error, error} -> error({:error, error})
    end
  end

  defp accept(ctx, line, legacy_ref, body) do
    events = %{
      scope: ctx.scope,
      actor: ctx.actor,
      api_client_id: nil,
      subtenant_id: nil,
      traceparent: nil
    }

    key = "import:" <> legacy_ref

    with {:ok, prepared} <- error(Events.prepare(events, body, dedup_key: key)) do
      work = fn _status ->
        case Events.accept(prepared, events) do
          {:ok, answer} -> {:ok, {202, [], Jason.encode!(answer)}}
          {:error, error} -> {:error, error}
        end
      end

      case Idempotency.run(ctx.scope, @endpoint, key, Jason.encode!(body), work) do
        {:ok, {kind, {_status, _headers, answer}}} -> confirmed(kind, line, legacy_ref, answer)
        {:error, error} -> error({:error, error})
      end
    end
  end

  defp confirmed(kind, line, legacy_ref, answer) do
    %{"id" => event_id} = Jason.decode!(answer)
    {:ok, id} = Relay.ExternalId.decode(event_id, ["evt"])
    confirmation = %{"line" => line, "legacy_ref" => legacy_ref, "event_id" => event_id}
    {:confirmed, kind, confirmation, record(line, "event", id)}
  end

  defp subscriber(ctx, external_id, fields) do
    input = %{external_id: external_id, fields: fields}

    with {:ok, plan} <- error(Relay.Subscribers.prepare(ctx.scope, input, :implicit)) do
      case Store.in_scope(ctx.scope, fn _status -> Relay.Subscribers.upsert(plan, nil) end) do
        {:ok, {result, id, _version}} when result in [:created, :updated, :unchanged] ->
          {:ok, result, id}

        {:ok, {other, _id, _version}} ->
          {:invalid, Atom.to_string(other)}

        {:error, reason} ->
          {:retry, reason}
      end
    end
  end

  defp provider_ref(_ctx, _recipient_id, nil), do: {:ok, nil}

  defp provider_ref(ctx, recipient_id, ref) when is_binary(ref) and byte_size(ref) in 1..256 do
    field = %{
      tenant_id: ctx.scope.tenant_id,
      environment: ctx.scope.environment,
      subject_id: recipient_id,
      retention_class: :recipient_profile,
      table: "import_records",
      column: "provider_ref_ct"
    }

    case Relay.Tenancy.encrypt_field(field, ref) do
      {:ok, ct} -> {:ok, ct}
      {:error, reason} -> {:retry, reason}
    end
  end

  defp provider_ref(_ctx, _recipient_id, _ref), do: {:invalid, "provider_ref_invalid"}

  defp record(line, kind, id, recipient_id \\ nil),
    do: {line, kind, Relay.Id.to_string(id), recipient_id, nil, nil}

  defp keys(row, allowed) do
    if Map.keys(row) -- allowed == [], do: :ok, else: {:invalid, "unknown_field"}
  end

  defp member(value, allowed, code),
    do: if(value in allowed, do: {:ok, value}, else: {:invalid, code})

  defp external_id(value) when is_binary(value) do
    if Regex.match?(@external_id, value),
      do: {:ok, value},
      else: {:invalid, "external_id_invalid"}
  end

  defp external_id(_value), do: {:invalid, "external_id_invalid"}

  defp error({:ok, value}), do: {:ok, value}

  defp error({:error, %Relay.Error{code: code}}) do
    case ErrorCatalog.fetch(code) do
      {:ok, %{retryable: false}} -> {:invalid, Atom.to_string(code)}
      _retryable -> {:retry, code}
    end
  end

  defp error({:error, reason}), do: {:retry, reason}
end
