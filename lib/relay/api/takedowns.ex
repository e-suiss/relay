defmodule Relay.Api.Takedowns do
  @moduledoc """
  Takedowns (TN-60): the installation operator closes access to the content of a message, a template or a sender identity of a tenant environment, and lifts a takedown again with a second explicit action. Taking a message down cancels its deliveries that were not handed to a provider with the rule `takedown.message`, ends its workflow run and hides its inbox items with reason `takedown`. Taking a template down archives it, so nothing is rendered from it and it cannot be published. Taking a sender identity down suspends it with the rule `takedown.sender_identity`. Lifting shows the hidden inbox items again, makes the template active with the live version it had and resumes the sender identity; cancelled deliveries stay cancelled. A target that was already archived or suspended is left as it was by both actions. Every takedown and every lifting is an audit record (`takedown.applied`, `takedown.lifted`, TN-47) written in the same transaction.
  """

  alias Relay.Api.ChannelManagement
  alias Relay.Api.Takedowns.Store
  alias Relay.Api.Views

  @targets %{
    "message" => {"ntf", "notification_id", :notification_not_found},
    "template" => {"tpl", "template_id", :template_not_found},
    "sender_identity" => {"snd", "sender_identity_id", :sender_identity_not_found}
  }

  @type answer :: {:ok, {pos_integer(), map()}} | {:error, Relay.Error.t()}

  # TN-60
  # TN-47
  @doc "Takes a target down; `201` with the takedown, or `200` with the takedown already in force."
  @spec take_down(Relay.Scope.t(), map(), Relay.Actor.t()) :: answer()
  def take_down(scope, %{"target" => target, "reason" => reason}, actor) do
    %{"type" => kind, "id" => text} = target
    {prefix, _column, not_found} = Map.fetch!(@targets, kind)

    with {:ok, target_id} <- target(text, prefix) do
      id = Relay.Id.generate()
      digest = ChannelManagement.digest(scope, "takedown.applied", id)

      transact(scope, fn ->
        case Store.take_down(id, kind, target_id, reason, digest, actor) do
          {:applied, id} -> {201, view(applied(id, kind, target_id))}
          {:already_active, existing} -> {200, view(Store.get(existing))}
          {:not_found, _none} -> refuse(Relay.Error.new(not_found, "no such " <> kind))
        end
      end)
    end
  end

  defp applied(id, kind, target_id) do
    if kind == "message", do: Relay.Inbox.takedown_sync(target_id)
    Store.get(id)
  end

  # TN-60
  # TN-47
  @doc "Lifts a takedown; lifting a lifted one changes nothing."
  @spec lift(Relay.Scope.t(), Relay.Id.t(), String.t(), Relay.Actor.t()) :: answer()
  def lift(scope, id, reason, actor) do
    digest = ChannelManagement.digest(scope, "takedown.lifted", id)

    transact(scope, fn ->
      case Store.lift(id, reason, digest, actor) do
        :not_found -> refuse(not_found())
        result -> {200, view(lifted(id, result))}
      end
    end)
  end

  defp lifted(id, result) do
    row = Store.get(id)

    if result == :lifted and row["target_kind"] == "message",
      do: Relay.Inbox.takedown_sync(row["notification_id"])

    row
  end

  @doc "Lists the takedowns of a scope after `after_id`, oldest first, as rows for `view/1`."
  @spec list(Relay.Scope.t(), Relay.Id.t() | nil, pos_integer()) ::
          {:ok, [map()]} | {:error, Relay.Error.t()}
  def list(scope, after_id, limit), do: transact(scope, fn -> Store.list(after_id, limit) end)

  @doc "The error of an unknown takedown."
  @spec not_found() :: Relay.Error.t()
  def not_found, do: Relay.Error.new(:takedown_not_found, "no such takedown")

  @doc "A takedown."
  @spec view(map()) :: map()
  def view(row) do
    {prefix, column, _not_found} = Map.fetch!(@targets, row["target_kind"])

    %{
      "object" => "takedown",
      "id" => Views.id("tkd", row["id"]),
      "target" => %{"type" => row["target_kind"], "id" => Views.id(prefix, row[column])},
      "reason" => row["reason"],
      "state" => row["state"],
      "hidden_inbox_items" => row["hidden_items"],
      "cancelled_deliveries" => row["cancelled_deliveries"],
      "lift_reason" => row["lift_reason"],
      "lifted_at" => row["lifted_at"],
      "created_at" => row["created_at"],
      "updated_at" => row["updated_at"]
    }
  end

  defp target(text, prefix) do
    case Relay.ExternalId.decode(text, [prefix]) do
      {:ok, id} ->
        {:ok, id}

      {:error, _error} ->
        detail = "not a #{prefix}_ identifier"

        {:error,
         Relay.Error.new(:validation_failed, detail, %{
           errors: [%{pointer: "/target/id", code: "invalid_format", detail: detail}]
         })}
    end
  end

  @spec refuse(Relay.Error.t()) :: no_return()
  defp refuse(error), do: Store.rollback(error)

  defp transact(scope, work) do
    case Store.in_scope(scope, fn _status -> work.() end) do
      {:ok, result} -> {:ok, result}
      {:error, %Relay.Error{} = error} -> {:error, error}
      {:error, _reason} -> {:error, Relay.Error.new(:database_error, "the takedown failed")}
    end
  end
end
