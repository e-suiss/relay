defmodule Relay.Api.PushContent do
  @moduledoc """
  The content a content-free push leaves out (CH-33, IN-38). Such a push carries only "there is a new notification" and its opaque identifier, the delivery identifier (`relay_id`); the app's notification service extension or data message handler then fetches the content from Relay over TLS with the subscriber's own token. The content is the delivery's render as it was sent, opened from its sealed render snapshot; nothing is rendered again. A delivery of another subscriber, of a channel other than push and Web Push, without a render, kept as a digest only (`security_subtype`, `retention: none`) or whose key was erased has no content here, and the device shows its neutral text.
  """

  @push ~w(push web_push)

  @type answer :: {:ok, {100..599, [{String.t(), String.t()}], map()}} | {:error, Relay.Error.t()}

  # CH-33
  # IN-38
  @doc "The rendered content of one of the subscriber's own push deliveries."
  @spec get(Relay.Scope.t(), Relay.Id.t(), Relay.Id.t()) :: answer()
  def get(%Relay.Scope{} = scope, subscriber_id, delivery_id) do
    read = fn _status ->
      {Relay.Ingest.delivery(delivery_id), Relay.TemplateStore.render_snapshots([delivery_id])}
    end

    case Relay.Ingest.in_event_scope(scope, read) do
      {:ok, {%{"channel" => channel} = delivery, [%{"recipient_id" => ^subscriber_id} = snap]}}
      when channel in @push ->
        content(scope, delivery, snap)

      {:ok, _other} ->
        {:error, not_found()}

      {:error, _reason} ->
        {:error, Relay.Error.new(:service_unavailable, "try again")}
    end
  end

  defp content(_scope, _delivery, %{"content_ct" => nil}), do: {:error, not_found()}

  defp content(scope, delivery, snap) do
    field = %{
      tenant_id: scope.tenant_id,
      environment: scope.environment,
      subject_id: snap["recipient_id"],
      retention_class: class(snap["retention_class"]),
      table: "render_snapshots",
      column: "content_ct"
    }

    with {:ok, plain} <- Relay.Tenancy.decrypt_field(field, snap["content_ct"]),
         {:ok, %{"output" => %{} = output}} <- Jason.decode(Relay.Redacted.expose(plain)) do
      {:ok, {200, [], view(delivery, snap, output)}}
    else
      _unreadable -> {:error, not_found()}
    end
  end

  defp class("commercial_message"), do: :commercial_message
  defp class(_content), do: :notification_content

  defp view(delivery, snap, output) do
    %{
      "object" => "push_content",
      "delivery_id" => Relay.ExternalId.encode("dlv", delivery["id"]),
      "notification_id" => Relay.ExternalId.encode("ntf", delivery["notification_id"]),
      "channel" => delivery["channel"],
      "locale" => snap["locale"],
      "content" => output
    }
  end

  defp not_found, do: Relay.Error.new(:delivery_not_found, "no push content for this delivery")
end
