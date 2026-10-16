defmodule Relay.RetentionClass do
  @moduledoc """
  Relay retention classes and the Access Appendix C classes each one maps to. Retention periods and their legal bases come from Access Appendix C; Relay keeps no periods of its own. A data key exists per subject and retention class, and each class carries one retention period.
  """

  @type t ::
          :recipient_profile
          | :notification_content
          | :delivery_record
          | :commercial_consent
          | :commercial_message
          | :preference
          | :audit
          | :traffic
          | :suppression
          | :dsr_log
          | :erasure_log

  @type access_class ::
          :profile
          | :message_log
          | :consent
          | :audit
          | :traffic
          | :suppression
          | :dsr_log
          | :erasure_log

  @mapping [
    recipient_profile: [:profile],
    notification_content: [:profile],
    delivery_record: [:message_log],
    commercial_consent: [:consent],
    commercial_message: [:message_log],
    preference: [:profile],
    audit: [:audit],
    traffic: [:traffic],
    suppression: [:suppression],
    dsr_log: [:dsr_log],
    erasure_log: [:erasure_log]
  ]

  @classes Keyword.keys(@mapping)
  @by_name Map.new(@classes, &{Atom.to_string(&1), &1})

  # OP-17
  # OP-18
  # OP-24
  # TN-60
  # C-85
  @doc "Returns every Relay retention class."
  @spec all() :: [t(), ...]
  def all, do: @classes

  @doc "Returns the Access Appendix C classes a Relay retention class maps to."
  @spec access_classes(t()) :: [access_class(), ...]
  def access_classes(class) when class in @classes, do: Keyword.fetch!(@mapping, class)

  @doc "Casts a retention class from its atom or its text form."
  @spec cast(term()) :: {:ok, t()} | {:error, Relay.Error.t()}
  def cast(class) when class in @classes, do: {:ok, class}

  def cast(name) when is_binary(name) do
    case Map.fetch(@by_name, name) do
      {:ok, class} -> {:ok, class}
      :error -> invalid()
    end
  end

  def cast(_other), do: invalid()

  @doc "Returns the text form of a retention class."
  @spec dump(t()) :: String.t()
  def dump(class) when class in @classes, do: Atom.to_string(class)

  defp invalid, do: {:error, Relay.Error.new(:invalid_retention_class, "not a retention class")}
end
