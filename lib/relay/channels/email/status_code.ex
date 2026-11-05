defmodule Relay.Channels.Email.StatusCode do
  @moduledoc """
  Enhanced mail system status codes (RFC 3463): `class.subject.detail`, where the class is 2 (success), 4 (persistent transient failure) or 5 (permanent failure) and the subject and detail have one to three digits.
  """

  @type t :: {2 | 4 | 5, non_neg_integer(), non_neg_integer()}

  @code ~r/\A([245])\.(\d{1,3})\.(\d{1,3})\z/
  @embedded ~r/(?<![\d.])([245])\.(\d{1,3})\.(\d{1,3})(?!\d|\.\d)/
  @reply ~r/(?:\A|[\s;])([245]\d\d)(?=[\s\-]|\z)/

  # CH-39
  @doc "Parses a status code such as `5.1.1`."
  @spec parse(String.t() | nil) :: {:ok, t()} | :error
  def parse(text) when is_binary(text) do
    case Regex.run(@code, String.trim(text), capture: :all_but_first) do
      [class, subject, detail] -> {:ok, triple(class, subject, detail)}
      nil -> :error
    end
  end

  def parse(_text), do: :error

  # CH-39
  @doc "The first status code written inside free text, such as an SMTP diagnostic; a dotted address is not taken for one."
  @spec find(String.t() | nil) :: {:ok, t()} | :error
  def find(text) when is_binary(text) do
    case Regex.run(@embedded, text, capture: :all_but_first) do
      [class, subject, detail] -> {:ok, triple(class, subject, detail)}
      nil -> :error
    end
  end

  def find(_text), do: :error

  @doc "The first three-digit SMTP reply code of a diagnostic, such as `550` in `smtp; 550 5.1.1 ...`."
  @spec reply_code(String.t() | nil) :: {:ok, 200..599} | :error
  def reply_code(text) when is_binary(text) do
    case Regex.run(@reply, text, capture: :all_but_first) do
      [code] -> {:ok, String.to_integer(code)}
      nil -> :error
    end
  end

  def reply_code(_text), do: :error

  @doc "Writes a status code as `class.subject.detail`."
  @spec to_string(t()) :: String.t()
  def to_string({class, subject, detail}), do: "#{class}.#{subject}.#{detail}"

  @doc "The class of a status code: `:success`, `:transient` or `:permanent`."
  @spec class(t()) :: :success | :transient | :permanent
  def class({2, _subject, _detail}), do: :success
  def class({4, _subject, _detail}), do: :transient
  def class({5, _subject, _detail}), do: :permanent

  defp triple(class, subject, detail) do
    {String.to_integer(class), String.to_integer(subject), String.to_integer(detail)}
  end
end
