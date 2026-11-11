defmodule Relay.Templates.Live do
  @moduledoc """
  Templates on the running send path (TP-50). At acceptance, inside the accepting transaction, `templates/2` resolves the live versions of an event's step templates once with sub-tenant inheritance, `choose/3` picks each delivery's cell (a channel without a variant is skipped with `template.variant_missing` and the route moves on, a recipient without a locale in the chain is skipped with `template.locale_missing`, a template without a live version with `template.not_published` or `template.archived`; WF-16, TP-11, TP-26, TP-51) and `pin/2` freezes the template, layout and partial versions and the locale with the delivery record (INV-48). The locale is the recipient's profile locale, else the locale of its most recently seen device, else the tenant's `default_locale`; `Accept-Language` never counts on the send path and there is no system default (TP-25). A fallback to the tenant default is counted as `template_locale_missing` by channel.

  On every run of the delivery job that the policy lattice lets send, `render/2` (the renderer step of `Relay.Delivery.Send`, configured as `config :relay, Relay.Delivery, renderer: Module`) renders the pinned versions only, never a newer one, with the event data, the brand fields (`Relay.TemplateStore.brand_resolve/2`, a producer template's text with the four tenant overrides), each pinned partial rendered first as the trusted `partial.<key>` and the render helpers `legal_footer` and `unsubscribe_url`. A delivery is rendered once (TP-60): the render records its digest, measures and content snapshot, sealed under the recipient's subject key of the category's retention class, or the digest only for security subtypes and `retention: none` (TP-40), and a later job run finds the render record and does not render again. `verify/2` renders again and compares the digest with the recorded one, for content that is not stored and for the channel attempts; a difference fails the delivery with `schema_violation`.

  `legal_footer` joins the brand's legal name, MERSIS number, contact and postal address and, for the `marketing` class, the commercial message mark in the cell's language (Turkish or English, English for every other language) (TP-55, TP-61). A render failure fails the delivery with its `failure_reason` and the `notification.render_failed` event, without retry (TP-41, INV-46). Every render emits `[:relay, :render, :stop]` with its duration and the bounded `channel` and `result` tags.

  `unsubscribe_url` is a stable placeholder until the preference links are issued; the channel adapter replaces it.

  The event's links are decrypted with its data and read as `links.<rel>`; the `primary` link is the push tap target and the inbox item's target (E-83).
  """

  use Boundary,
    top_level?: true,
    deps: [Relay, Relay.Templates, Relay.TemplateStore, Relay.Tenancy, Relay.Workflow],
    exports: []

  alias Relay.Scope
  alias Relay.Templates.Live.Store
  alias Relay.TemplateStore

  @channels Map.new(
              ~w(push web_push email sms voice whatsapp slack teams telegram discord in_app
                 webhook)a,
              &{Atom.to_string(&1), &1}
            )
  @sensitivities %{"public" => :public, "personal" => :personal, "sensitive" => :sensitive}
  @encodings %{
    "transliterate" => :transliterate,
    "turkish_shift" => :turkish_shift,
    "ucs2" => :ucs2
  }
  @classes %{
    "notification_content" => :notification_content,
    "commercial_message" => :commercial_message
  }
  @unsubscribe "urn:relay:unsubscribe"
  @not_published "template.not_published"
  @legal ~w(legal_name mersis contact postal_address)
  @marks %{"tr" => "Ticari elektronik iletidir.", "en" => "This is a commercial message."}

  @type templates :: %{
          required(:default_locale) => term(),
          optional(:default_timezone) => term(),
          optional(String.t()) => map()
        }
  @type plan :: map()
  @type skip :: {:skip, String.t(), String.t(), map()}
  @type result :: :rendered | :failed | :done | {:error, {:input_unavailable, atom()}}

  # TP-11
  # TP-36
  # TP-51
  @doc "Resolves the live versions of `keys` for a sub-tenant (`nil` for the tenant level) and the tenant's `default_locale` and `default_timezone`, inside the caller's transaction."
  @spec templates([String.t()], Relay.Id.t() | nil) :: templates()
  def templates(keys, subtenant_id) do
    rows = TemplateStore.template_live(Enum.uniq(keys), subtenant_id)
    index = Store.cell_index(for %{"template_version_id" => id} <- rows, id != nil, do: id)
    defaults = Store.defaults(subtenant_id)

    rows
    |> Map.new(fn row -> {row["key"], entry(row, index[row["template_version_id"]])} end)
    |> Map.put(:default_locale, defaults["default_locale"])
    |> Map.put(:default_timezone, defaults["default_timezone"])
  end

  defp entry(row, index) do
    %{
      key: row["key"],
      rule_id: row["rule_id"] || if(row["template_version_id"], do: nil, else: @not_published),
      template_version_id: row["template_version_id"],
      version_no: row["version_no"],
      layout_key: index && index["layout_key"],
      layout_version_id: row["layout_version_id"],
      partial_version_ids: row["partial_version_ids"] || [],
      locales: (index && index["locales"]) || %{}
    }
  end

  # WF-16
  # TP-11
  # TP-25
  # TP-26
  # TP-51
  @doc "Chooses the cell of one delivery: `{:ok, plan}` to pin, or `{:skip, reason, rule_id, detail}` when the template cannot send on this channel to this recipient. `recipient` is the subscriber row with its profile `locale` and the `device_locale` of its most recently seen device that carries one (TP-25)."
  @spec choose(templates(), %{template: String.t(), channel: String.t()}, map()) ::
          {:ok, plan()} | skip()
  def choose(templates, %{template: key, channel: channel}, recipient) do
    entry = Map.get(templates, key) || entry(%{"key" => key}, nil)
    detail = %{"template" => template_ref(entry), "channel" => channel}

    cond do
      entry.rule_id != nil ->
        {:skip, "template_unavailable", entry.rule_id, detail}

      unpinnable?(entry) ->
        {:skip, "template_unavailable", @not_published, detail}

      Map.get(entry.locales, channel, []) == [] ->
        {:skip, "no_channel_variant", "template.variant_missing", detail}

      true ->
        locale(entry, channel, recipient, templates.default_locale, detail)
    end
  end

  defp unpinnable?(entry) do
    (entry.layout_key != nil and entry.layout_version_id == nil) or
      Enum.any?(entry.partial_version_ids, &is_nil/1)
  end

  defp locale(entry, channel, recipient, default_locale, detail) do
    candidates = %{
      profile: recipient["locale"],
      device: recipient["device_locale"],
      tenant_default: default_locale,
      surface: :send
    }

    case Relay.Templates.resolve_locale(candidates, Map.fetch!(entry.locales, channel)) do
      {:ok, resolution} ->
        {:ok,
         %{
           channel: channel,
           template_version_id: entry.template_version_id,
           layout_version_id: entry.layout_version_id,
           partial_version_ids: entry.partial_version_ids,
           locale: resolution.locale,
           locale_fallback: resolution.template_locale_missing
         }}

      {:error, :locale_missing} ->
        requested = recipient["locale"] || recipient["device_locale"] || default_locale
        detail = if is_binary(requested), do: Map.put(detail, "locale", requested), else: detail
        {:skip, "template_locale_missing", "template.locale_missing", detail}
    end
  end

  defp template_ref(%{version_no: version} = entry) when is_integer(version),
    do: %{"key" => entry.key, "version" => version}

  defp template_ref(entry), do: %{"key" => entry.key}

  # TP-50
  # INV-48
  # TP-26
  @doc "Pins a chosen plan on an opened delivery inside the accepting transaction; a fallback to the tenant's default locale is counted as `template_locale_missing`."
  @spec pin(Relay.Id.t(), plan()) :: atom()
  def pin(delivery_id, plan) do
    result = TemplateStore.plan_pin(delivery_id, plan)

    if result == :pinned and plan.locale_fallback do
      channel = Map.fetch!(@channels, plan.channel)
      :telemetry.execute([:relay, :templates, :locale_missing], %{count: 1}, %{channel: channel})
    end

    result
  end

  # TP-40
  # TP-41
  # TP-49
  # TP-50
  # INV-26
  # INV-46
  # INV-48
  @doc "Renders the pinned plan of a delivery the lattice lets send and records the render or its failure: `:rendered`, `:failed` (the delivery failed with its `failure_reason`, no retry), `:done` (the delivery is gone or already closed) or `{:error, {:input_unavailable, input}}` when an input cannot be read, so the job retries."
  @spec render(Scope.t(), Relay.Id.t()) :: result()
  def render(%Scope{} = scope, delivery_id), do: render(scope, delivery_id, :once)

  # TP-50
  # TP-60
  @doc "Renders the pinned plan of a rendered delivery again and compares its digest with the recorded one; a difference fails the delivery with `schema_violation`. Used where the content is not stored (security subtypes, `retention: none`) and by the channel attempts. Returns as `render/2`."
  @spec verify(Scope.t(), Relay.Id.t()) :: result()
  def verify(%Scope{} = scope, delivery_id), do: render(scope, delivery_id, :verify)

  # TP-50
  # TP-60
  # CH-2
  @doc "Renders the pinned plan of a rendered delivery again for its channel attempt, compares the digest as `verify/2` does and returns the encoded rendered content as `{:rendered, content}`; otherwise returns as `render/2`."
  @spec prepare(Scope.t(), Relay.Id.t()) ::
          {:rendered, binary()}
          | :rendered
          | :failed
          | :done
          | {:error, {:input_unavailable, atom()}}
  def prepare(%Scope{} = scope, delivery_id), do: content(scope, delivery_id, :verify)

  defp render(scope, delivery_id, mode) do
    case content(scope, delivery_id, mode) do
      {:rendered, _content} -> :rendered
      other -> other
    end
  end

  defp content(scope, delivery_id, mode) do
    started = Relay.Clock.monotonic_ms()

    case load(scope, delivery_id) do
      {:ok, nil} ->
        :done

      {:ok, {:no_plan, channel}} ->
        failed(scope, delivery_id, channel, started, {:schema_violation, cause("plan_missing")})

      {:ok, %{plan: %{"render_digest" => digest}}} when is_binary(digest) and mode == :once ->
        :rendered

      {:ok, input} ->
        run(scope, delivery_id, input, started)

      {:error, _reason} ->
        {:error, {:input_unavailable, :template}}
    end
  end

  defp load(scope, delivery_id) do
    Store.in_scope(scope, fn _status ->
      with %{} = delivery <- Store.delivery(delivery_id),
           %{} = plan <- TemplateStore.plan(delivery_id) || {:no_plan, delivery["channel"]} do
        version = Store.template_version(plan["template_version_id"])
        layout = plan["layout_version_id"] && Store.layout_content(plan["layout_version_id"])
        partials = Store.partial_contents(plan["partial_version_ids"] || [])

        %{
          delivery: delivery,
          plan: plan,
          version: version,
          layout: layout,
          partials: partials,
          defaults: Store.defaults(delivery["subtenant_id"]),
          brand: TemplateStore.brand_resolve(delivery["subtenant_id"], version["id"]),
          policy: TemplateStore.render_policy(delivery_id),
          digest: Relay.Workflow.digest_render(delivery_id) || %{}
        }
      end
    end)
  end

  defp run(scope, delivery_id, input, started) do
    channel = input.delivery["channel"]

    with {:ok, data} <- event_data(scope, input.delivery),
         {:ok, links} <- links(scope, input.delivery) do
      rendered = Relay.Templates.render_cell(Map.put(cell_input(input, data), :links, links))
      finish(scope, delivery_id, input, channel, started, rendered)
    else
      {:error, :erased} ->
        failed(scope, delivery_id, channel, started, {:schema_violation, cause("data_erased")})

      {:error, :unavailable} ->
        {:error, {:input_unavailable, :event_data}}
    end
  end

  defp finish(scope, delivery_id, input, channel, started, {:ok, rendered}) do
    case record(scope, delivery_id, input, rendered) do
      :recorded ->
        emit(channel, :ok, started)
        {:rendered, rendered.content}

      :digest_mismatch ->
        mismatch = {:schema_violation, cause("digest_mismatch")}
        failed(scope, delivery_id, channel, started, mismatch)

      :done ->
        :done

      {:error, _reason} = error ->
        error
    end
  end

  defp finish(scope, delivery_id, _input, channel, started, {:error, reason, detail}),
    do: failed(scope, delivery_id, channel, started, {reason, detail})

  defp cell_input(input, data) do
    %{delivery: delivery, version: version, plan: plan} = input
    channel = Map.fetch!(@channels, delivery["channel"])
    locale = plan["locale"]

    %{
      channel: channel,
      cell: cell(get_in(version, ["cells", delivery["channel"]]) || %{}, locale),
      locale: locale,
      time_zone: time_zone(delivery["timezone"], input.defaults["default_timezone"]),
      data: data,
      recipient: %{},
      digest: Map.get(input, :digest, %{}),
      brand: brand(input.brand),
      helpers: helpers(input.brand, delivery["message_class"], locale),
      partials: partials(input.partials, locale),
      event_schema: delivery["event_schema"],
      schema: schema(delivery["event_schema"]),
      sensitivity: Map.get(@sensitivities, version["sensitivity"], :personal),
      sms_encoding: Map.get(@encodings, version["sms_encoding"], :turkish_shift),
      message_class: delivery["message_class"] || "",
      allow_raw: version["allow_raw"] == true,
      layout: if(channel == :email, do: input.layout)
    }
  end

  # TP-26
  defp cell(cells, locale) do
    case Map.fetch(cells, locale) do
      {:ok, cell} -> cell
      :error -> Enum.find_value(cells, %{}, &same_locale(&1, locale))
    end
  end

  defp same_locale({tag, cell}, locale),
    do: if(Relay.Locale.new(tag) == {:ok, locale}, do: cell)

  defp time_zone(own, default) do
    Enum.find([own, default], "Etc/UTC", fn zone ->
      is_binary(zone) and match?({:ok, _zone}, Relay.TimeZone.new(zone))
    end)
  end

  # TP-61
  defp mark(locale) do
    language = locale |> String.split("-") |> hd()
    Map.get(@marks, language, @marks["en"])
  end

  # TP-35
  # TP-61
  defp partials(partials, locale) do
    Map.new(partials, fn {key, content} -> {key, partial_source(content, locale)} end)
  end

  defp partial_source(%{"bodies" => bodies} = content, locale) when is_map(bodies) do
    chain = Relay.Templates.locale_chain(locale) ++ [content["default_locale"]]
    Enum.find_value(chain, &string(bodies[&1]))
  end

  defp partial_source(_content, _locale), do: nil

  defp string(value) when is_binary(value), do: value
  defp string(_value), do: nil

  defp schema(event_schema) when is_map(event_schema) do
    case Relay.Workflow.event_schema(event_schema) do
      {:ok, root} -> root
      {:error, _detail} -> nil
    end
  end

  defp schema(_event_schema), do: nil

  # TP-36
  # TP-52
  defp brand(fields) do
    for {field, %{value: value}} <- fields, value != nil, into: %{}, do: {field, value}
  end

  # TP-55
  # TP-61
  defp helpers(fields, class, locale) do
    brand = brand(fields)
    mark = if class == "marketing", do: [mark(locale)], else: []

    legal =
      (Enum.map(@legal, &brand[&1]) ++ mark)
      |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
      |> Enum.join(" | ")

    %{"legal_footer" => legal, "unsubscribe_url" => @unsubscribe}
  end

  defp event_data(_scope, %{"data_erased_at" => %DateTime{}}), do: {:error, :erased}

  defp event_data(_scope, %{"data_ct" => nil}), do: {:ok, %{}}

  defp event_data(scope, %{"data_ct" => ct, "data_key_id" => key_id}) do
    field = payload_field(scope, key_id, "data_ct")

    with {:ok, plain} <- Relay.Tenancy.decrypt_field(field, ct),
         {:ok, data} when is_map(data) <- Jason.decode(Relay.Redacted.expose(plain)) do
      {:ok, data}
    else
      _unreadable -> {:error, :unavailable}
    end
  end

  # E-83
  defp links(_scope, %{"links_ct" => nil}), do: {:ok, %{}}

  defp links(scope, %{"links_ct" => ct, "data_key_id" => key_id}) do
    field = payload_field(scope, key_id, "links_ct")

    with {:ok, plain} <- Relay.Tenancy.decrypt_field(field, ct),
         {:ok, links} when is_list(links) <- Jason.decode(Relay.Redacted.expose(plain)) do
      {:ok, Map.new(links, &{&1["rel"], &1["href"]})}
    else
      _unreadable -> {:error, :unavailable}
    end
  end

  defp payload_field(scope, key_id, column) do
    %{
      tenant_id: scope.tenant_id,
      environment: scope.environment,
      subject_id: nil,
      retention_class: :notification_content,
      table: "event_payloads",
      column: column,
      key_id: key_id
    }
  end

  # TP-40
  # TP-50
  defp record(scope, delivery_id, input, rendered) do
    with {:ok, {content_ct, key_id}} <- seal(scope, input, rendered) do
      result =
        Store.in_scope(scope, fn _status ->
          TemplateStore.render_record(
            delivery_id,
            rendered.digest,
            rendered.measures,
            content_ct,
            key_id
          )
        end)

      case result do
        {:ok, recorded} when recorded in [:recorded, :matched] -> :recorded
        {:ok, :digest_mismatch} -> :digest_mismatch
        {:ok, closed} when closed in [:already_terminal, :delivery_not_found] -> :done
        _other -> {:error, {:input_unavailable, :render_policy}}
      end
    end
  end

  defp seal(_scope, %{plan: %{"render_digest" => digest}}, _rendered) when is_binary(digest),
    do: {:ok, {nil, nil}}

  defp seal(_scope, %{policy: %{"digest_reason" => reason}}, _rendered) when is_binary(reason),
    do: {:ok, {nil, nil}}

  defp seal(scope, %{policy: policy, delivery: delivery}, rendered) do
    class = Map.fetch!(@classes, policy["retention_class"])

    field = sealed(scope, delivery, class)

    with {:ok, key_id, opts} <- content_key(scope, delivery["recipient_id"], class, policy),
         {:ok, ct} <- Relay.Tenancy.encrypt_field(field, rendered.content, opts) do
      {:ok, {ct, key_id}}
    else
      {:error, _reason} -> {:error, {:input_unavailable, :content_key}}
    end
  end

  defp sealed(scope, delivery, class) do
    %{
      tenant_id: scope.tenant_id,
      environment: scope.environment,
      subject_id: delivery["recipient_id"],
      retention_class: class,
      table: "render_snapshots",
      column: "content_ct"
    }
  end

  # OP-18
  defp content_key(_scope, _recipient_id, _class, %{"content_key_id" => <<_::128>> = id}),
    do: {:ok, id, []}

  defp content_key(scope, recipient_id, class, _policy) do
    id = Relay.Id.generate()

    with {:ok, wrap_id} <- Relay.Tenancy.active_tenant_key(scope, :dek_wrap),
         {:ok, %{wrapped_dek: wrapped, data_key: data_key}} <-
           Relay.Tenancy.generate_subject_key(scope, wrap_id, recipient_id, class),
         {:ok, created} <- register_key(scope, id, recipient_id, class, wrapped, wrap_id) do
      case created do
        {:created, ^id} -> {:ok, id, [data_key: data_key]}
        {:exists, key_id} -> {:ok, key_id, []}
        {missing, _id} -> {:error, missing}
      end
    end
  end

  defp register_key(scope, id, recipient_id, class, wrapped, wrap_id) do
    Store.in_scope(scope, fn _status ->
      Store.subject_key_create(id, recipient_id, Atom.to_string(class), wrapped, wrap_id)
    end)
  end

  # TP-41
  # INV-46
  defp failed(scope, delivery_id, channel, started, {reason, detail}) do
    fail = fn _status -> TemplateStore.render_fail(delivery_id, reason, detail) end
    result = Store.in_scope(scope, fail)

    case result do
      {:ok, :failed} ->
        emit(channel, reason, started)
        :failed

      {:ok, _closed} ->
        :done

      {:error, _reason} ->
        {:error, {:input_unavailable, :render_failure}}
    end
  end

  defp cause(code), do: %{"cause" => code}

  # T-63
  defp emit(channel, result, started) do
    duration = max(Relay.Clock.monotonic_ms() - started, 0)
    tags = %{channel: Map.get(@channels, channel, :unknown), result: result}
    :telemetry.execute([:relay, :render, :stop], %{duration: duration}, tags)
  end
end
