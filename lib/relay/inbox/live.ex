defmodule Relay.Inbox.Live do
  @moduledoc """
  The inbox on the running send path (IN-2, IN-4, IN-44, IN-49). `deliver/3` is the `in_app` adapter of the channel step: it takes the delivery's rendered content (the render is stored, the template never runs again for the item), reads the delivery's retention class and, for a digest delivery, its digest render (total activities and actors and the collapse key, WF-29), checks the published limits and seals the content under the recipient's subject key of that class, so an erasure shreds it (IN-44, IN-45). The item, its counters, its stream publication and the delivery's `delivered` evidence then commit in one transaction (`Relay.Inbox.record/2`). Content over a limit fails the delivery with `inbox_item_too_large` (an action URL that is not `https` with `schema_violation`), without retry (TP-41).

  `open/2` is the content opener of `Relay.Inbox`: it unseals item content after the read transaction; content that no longer opens, as after an erasure, is `nil`.
  """

  use Boundary,
    top_level?: true,
    deps: [
      Relay,
      Relay.Inbox,
      Relay.Platform,
      Relay.Tenancy,
      Relay.TemplateStore,
      Relay.Workflow
    ],
    exports: []

  alias Relay.Inbox.Live.Store
  alias Relay.Scope
  alias Relay.TemplateStore

  @classes %{
    "notification_content" => :notification_content,
    "commercial_message" => :commercial_message
  }

  @type result :: :ok | {:skip, String.t()} | {:error, term()}

  # IN-2
  # IN-4
  # IN-49
  # WF-29
  # TP-41
  @doc "Writes the inbox item of a rendered `in_app` delivery from its rendered content (the renderer's content document or its output); returns `:ok`, `{:skip, rule_id}` when the recipient is no longer an active subscriber, or `{:error, reason}` when an input cannot be read, so the job retries."
  @spec deliver(Scope.t(), map(), binary() | map()) :: result()
  def deliver(%Scope{} = scope, %{"id" => delivery_id} = delivery, content) do
    with {:ok, %{policy: policy, digest: digest}} <- inputs(scope, delivery_id),
         {:ok, item} <- item(content) do
      meta = meta(digest)

      case Relay.Inbox.check_item(item, meta) do
        :ok -> seal(scope, delivery, policy, item, meta)
        {:error, reason, detail} -> fail(scope, delivery_id, reason, detail)
      end
    end
  end

  defp inputs(scope, delivery_id) do
    read = fn _status ->
      %{
        policy: TemplateStore.render_policy(delivery_id),
        digest: Relay.Workflow.digest_render(delivery_id)
      }
    end

    case Store.in_scope(scope, read) do
      {:ok, %{policy: %{"result" => "ok"}} = inputs} -> {:ok, inputs}
      {:ok, _not_found} -> {:error, {:input_unavailable, :render_policy}}
      {:error, _reason} -> {:error, {:input_unavailable, :render_policy}}
    end
  end

  defp item(content) when is_binary(content) do
    case Jason.decode(content) do
      {:ok, %{} = document} -> item(document)
      _invalid -> {:error, {:input_unavailable, :content}}
    end
  end

  defp item(%{"output" => %{} = output}), do: item(output)

  defp item(%{} = output) do
    {:ok,
     %{
       "title" => output["title"],
       "body" => output["body"],
       "avatar_url" => output["avatar"] || output["avatar_url"],
       "url" => output["url"],
       "actions" => output["actions"] || [],
       "data" => output["data"] || [],
       "locale" => output["locale"],
       "dir" => output["dir"]
     }}
  end

  # WF-29
  defp meta(%{"collapse_key" => key} = digest) when is_binary(key) do
    %{
      tags: [],
      group_key: "digest:" <> key,
      activity_count: positive(digest["total_activities"], 1),
      actor_count: positive(digest["total_actors"], 0)
    }
  end

  defp meta(_digest), do: %{tags: [], group_key: nil, activity_count: 1, actor_count: 0}

  defp positive(value, _default) when is_integer(value) and value >= 1, do: value
  defp positive(_value, default), do: default

  # IN-44
  # IN-45
  defp seal(scope, delivery, policy, item, meta) do
    recipient_id = policy["recipient_id"]
    class = Map.fetch!(@classes, policy["retention_class"])
    plain = Jason.encode!(item)

    field = field(scope, recipient_id, class)

    with {:ok, key_id, opts} <- content_key(scope, recipient_id, class, policy),
         {:ok, ct} <- Relay.Tenancy.encrypt_field(field, plain, opts) do
      record(scope, delivery, item, meta, %{ct: ct, key_id: key_id, digest: sha256(plain)})
    else
      {:error, _reason} -> {:error, {:input_unavailable, :content_key}}
    end
  end

  defp record(scope, delivery, item, meta, sealed) do
    attrs = %{
      id: Relay.Id.generate(),
      delivery_id: delivery["id"],
      category: delivery["category_key"] || delivery["category"],
      group_key: meta.group_key,
      severity: nil,
      tags: meta.tags,
      content_ct: sealed.ct,
      content_key_id: sealed.key_id,
      content_digest: sealed.digest,
      locale: item["locale"],
      dir: item["dir"],
      activity_count: meta.activity_count,
      actor_count: meta.actor_count
    }

    case Relay.Inbox.record(scope, attrs) do
      {:ok, {_code, _item_id, _version}} ->
        _ = Relay.Platform.wake_outbox()
        :ok

      {:ok, :recipient_inactive} ->
        {:skip, "subscriber.suspended"}

      {:ok, _gone} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp sha256(plain), do: :crypto.hash(:sha256, plain)

  defp field(scope, recipient_id, class) do
    %{
      tenant_id: scope.tenant_id,
      environment: scope.environment,
      subject_id: recipient_id,
      retention_class: class,
      table: "inbox_items",
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
        {_missing, _id} -> {:error, :recipient_not_found}
      end
    end
  end

  defp register_key(scope, id, recipient_id, class, wrapped, wrap_id) do
    Store.in_scope(scope, fn _status ->
      Store.subject_key_create(id, recipient_id, Atom.to_string(class), wrapped, wrap_id)
    end)
  end

  # TP-41
  # IN-49
  defp fail(scope, delivery_id, reason, detail) do
    fail = fn _status -> TemplateStore.render_fail(delivery_id, reason, detail) end

    case Store.in_scope(scope, fail) do
      {:ok, _result} -> :ok
      {:error, _reason} -> {:error, {:input_unavailable, :render_failure}}
    end
  end

  # IN-44
  @doc "Unseals the content of item rows, in order; a row whose content no longer opens gives `nil`. Runs outside any transaction."
  @spec open(Scope.t(), [map()]) :: [map() | nil]
  def open(%Scope{} = scope, rows), do: Enum.map(rows, &open_row(scope, &1))

  defp open_row(scope, row) do
    field = field(scope, row["recipient_id"], Map.fetch!(@classes, row["retention_class"]))

    with {:ok, plain} <- Relay.Tenancy.decrypt_field(field, row["content_ct"]),
         {:ok, %{} = content} <- Jason.decode(Relay.Redacted.expose(plain)) do
      content
    else
      _unreadable -> nil
    end
  end
end
