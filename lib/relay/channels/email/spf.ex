defmodule Relay.Channels.Email.Spf do
  @moduledoc """
  SPF lookup counting of a sending domain (RFC 7208, CH-36). The record is walked through every `include` and `redirect` and each DNS-querying term is counted: `include`, `a`, `mx`, `ptr`, `exists` and `redirect`. More than 10 lookups or more than 2 void lookups (a name with no answer) is a `permerror` at receivers, so it is an error here. A domain spec with a macro is counted and not followed; `ptr` is counted and warned about.

  Findings are atoms: errors `spf_missing`, `spf_multiple`, `spf_include_without_record`, `spf_loop`, `spf_syntax`, `spf_lookup_limit`, `spf_void_limit`, `spf_mx_too_many` and `spf_temperror`; warnings `spf_ptr` and `spf_macro`.
  """

  @max_lookups 10
  @max_void 2
  @max_mx 10

  @type result :: %{
          record: String.t() | nil,
          lookups: non_neg_integer(),
          void_lookups: non_neg_integer(),
          errors: [atom()],
          warnings: [atom()]
        }

  # CH-36
  @doc "Counts the SPF lookups of `domain` with `resolver`, a `Relay.Channels.Email.Resolver`."
  @spec check(String.t(), module()) :: result()
  def check(domain, resolver) when is_binary(domain) and is_atom(resolver) do
    domain = String.downcase(domain, :ascii)
    state = %{lookups: 0, void: 0, errors: [], warnings: [], visited: MapSet.new([domain])}

    {record, state} =
      case records(domain, resolver) do
        {:ok, [record]} -> {record, walk(record, domain, resolver, state)}
        {:ok, []} -> {nil, add(state, :errors, :spf_missing)}
        {:ok, _many} -> {nil, add(state, :errors, :spf_multiple)}
        {:error, _reason} -> {nil, add(state, :errors, :spf_temperror)}
      end

    state =
      state
      |> add_if(state.lookups > @max_lookups, :errors, :spf_lookup_limit)
      |> add_if(state.void > @max_void, :errors, :spf_void_limit)

    %{
      record: record,
      lookups: state.lookups,
      void_lookups: state.void,
      errors: Enum.reverse(state.errors),
      warnings: Enum.reverse(state.warnings)
    }
  end

  @doc "Whether a TXT record, its strings joined, is an SPF record."
  @spec spf?(String.t()) :: boolean()
  def spf?(record) do
    case String.downcase(record, :ascii) do
      "v=spf1" -> true
      "v=spf1 " <> _terms -> true
      _other -> false
    end
  end

  defp records(domain, resolver) do
    case resolver.txt(domain) do
      {:ok, records} -> {:ok, records |> Enum.map(&Enum.join/1) |> Enum.filter(&spf?/1)}
      {:error, reason} when reason in [:nxdomain, :no_data] -> {:ok, []}
      {:error, reason} -> {:error, reason}
    end
  end

  defp walk(record, domain, resolver, state) do
    record
    |> String.split([" ", "\t"], trim: true)
    |> tl()
    |> Enum.reduce(state, &term(&1, domain, resolver, &2))
  end

  defp term(term, domain, resolver, state) do
    term = term |> String.replace(~r/\A[+\-~?]/, "") |> String.downcase(:ascii)

    term |> mechanism() |> evaluate(domain, resolver, state)
  end

  defp evaluate({kind, target}, _domain, resolver, state) when kind in [:include, :redirect],
    do: follow(target, resolver, state)

  defp evaluate({:a, target}, domain, resolver, state),
    do: address(target || domain, resolver, counted(state))

  defp evaluate({:mx, target}, domain, resolver, state),
    do: mx(target || domain, resolver, counted(state))

  defp evaluate({:exists, target}, _domain, resolver, state),
    do: address(target, resolver, counted(state))

  defp evaluate(:ptr, _domain, _resolver, state),
    do: state |> counted() |> add(:warnings, :spf_ptr)

  defp evaluate(:none, _domain, _resolver, state), do: state
  defp evaluate(:syntax, _domain, _resolver, state), do: add(state, :errors, :spf_syntax)

  defp mechanism("include:" <> target), do: {:include, target}
  defp mechanism("redirect=" <> target), do: {:redirect, target}
  defp mechanism("exists:" <> target), do: {:exists, target}
  defp mechanism("ptr" <> _rest), do: :ptr
  defp mechanism("all"), do: :none
  defp mechanism("ip4:" <> _network), do: :none
  defp mechanism("ip6:" <> _network), do: :none
  defp mechanism("exp=" <> _explanation), do: :none
  defp mechanism("a"), do: {:a, nil}
  defp mechanism("a/" <> _cidr), do: {:a, nil}
  defp mechanism("a:" <> target), do: {:a, without_cidr(target)}
  defp mechanism("mx"), do: {:mx, nil}
  defp mechanism("mx/" <> _cidr), do: {:mx, nil}
  defp mechanism("mx:" <> target), do: {:mx, without_cidr(target)}

  defp mechanism(other) do
    if Regex.match?(~r/\A[a-z][a-z0-9_.\-]*=/, other), do: :none, else: :syntax
  end

  defp without_cidr(target), do: target |> String.split("/", parts: 2) |> hd()

  defp follow(target, resolver, state) do
    state = counted(state)

    cond do
      macro?(target) ->
        add(state, :warnings, :spf_macro)

      MapSet.member?(state.visited, target) ->
        add(state, :errors, :spf_loop)

      state.lookups > @max_lookups ->
        state

      true ->
        state = %{state | visited: MapSet.put(state.visited, target)}

        case records(target, resolver) do
          {:ok, [record]} -> walk(record, target, resolver, state)
          {:ok, []} -> state |> void() |> add(:errors, :spf_include_without_record)
          {:ok, _many} -> add(state, :errors, :spf_multiple)
          {:error, _reason} -> add(state, :errors, :spf_temperror)
        end
    end
  end

  defp address(target, resolver, state) do
    if macro?(target) do
      add(state, :warnings, :spf_macro)
    else
      found = Enum.any?([:a, :aaaa], &match?({:ok, [_ | _]}, resolver.lookup(target, &1)))

      if found, do: state, else: void(state)
    end
  end

  defp mx(target, resolver, state) do
    if macro?(target) do
      add(state, :warnings, :spf_macro)
    else
      case resolver.lookup(target, :mx) do
        {:ok, records} when length(records) > @max_mx -> add(state, :errors, :spf_mx_too_many)
        {:ok, _records} -> state
        {:error, reason} when reason in [:nxdomain, :no_data] -> void(state)
        {:error, _reason} -> add(state, :errors, :spf_temperror)
      end
    end
  end

  defp macro?(target), do: String.contains?(target, "%")

  defp counted(state), do: %{state | lookups: state.lookups + 1}
  defp void(state), do: %{state | void: state.void + 1}

  defp add(state, key, finding) do
    if finding in Map.fetch!(state, key),
      do: state,
      else: Map.update!(state, key, &[finding | &1])
  end

  defp add_if(state, true, key, finding), do: add(state, key, finding)
  defp add_if(state, false, _key, _finding), do: state
end
