defmodule Relay.Templates.Finding do
  @moduledoc """
  One publish gate finding (TP-32). Every check of a template version (channel render rules, sanitizers, lints) reports its result in this one shape, so the publish gate can combine them: a `:hard` finding blocks the publish, a `:warning` finding is passed with "publish with warnings" and recorded.

  Fields: `check` names the check (`:push_payload_size`, `:sensitive_terms`, …), `channel` the channel variant (`:sms`, `:push`, `:email`, `:whatsapp`, `:inbox`, `:webhook`) or `nil` for a template-wide check, `locale` the BCP 47 tag of the cell or `nil`, `pointer` a JSON Pointer to the field inside the variant (`"/subject"`, `"/actions/0/url"`) or `nil`, and `detail` a map of measurements and matches. `detail` carries counts, limits, matched dictionary terms and code points, never rendered recipient content.
  """

  @type level :: :hard | :warning
  @type t :: %__MODULE__{
          check: atom(),
          level: level(),
          channel: atom() | nil,
          locale: String.t() | nil,
          pointer: String.t() | nil,
          detail: map()
        }

  @enforce_keys [:check, :level]
  defstruct [:check, :level, channel: nil, locale: nil, pointer: nil, detail: %{}]

  # TP-32
  @doc "Builds a finding; `fields` may set `channel`, `locale`, `pointer` and `detail`."
  @spec new(atom(), level(), keyword()) :: t()
  def new(check, level, fields \\ []) when is_atom(check) and level in [:hard, :warning] do
    %__MODULE__{
      check: check,
      level: level,
      channel: Keyword.get(fields, :channel),
      locale: Keyword.get(fields, :locale),
      pointer: Keyword.get(fields, :pointer),
      detail: Keyword.get(fields, :detail, %{})
    }
  end

  # TP-32
  @doc "True when any of the findings blocks the publish."
  @spec blocking?([t()]) :: boolean()
  def blocking?(findings), do: Enum.any?(findings, &(&1.level == :hard))

  # TP-32
  @doc "Splits findings into `{hard, warnings}`, keeping their order."
  @spec split([t()]) :: {[t()], [t()]}
  def split(findings), do: Enum.split_with(findings, &(&1.level == :hard))
end
