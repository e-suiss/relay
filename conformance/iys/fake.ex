defmodule RelayTest.IysFake do
  @moduledoc """
  An in-process fake of the İYS API (PC-56), written against `conformance/iys/openapi.yaml`, the transcription of the official document. It is a Plug: a test reaches it through Req's `:plug` option (`config :relay, Relay.Iys, http: [plug: {RelayTest.IysFake, []}]`), and `child_spec/1` with `:port` also serves it over HTTP with Bandit. Its state lives in one process, started with `start_link/1`.

  What it does as the document says:

    * `POST /oauth2/token`: password and refresh grants as JSON or as a form, a 2 hour access token and a 4 hour refresh token, a new refresh token with every refresh, `H251` for wrong credentials and, past the hourly limit, `429 H084`;
    * every other operation needs a live bearer token (`401 H351`) and the service provider's `iysCode` (`403 H353`);
    * `POST /v2/sps/{iysCode}/brands/{brandCode}/consents`: the field checks with their error codes and `location`, `H175` for a first record that is `RET`, `H174` for the status the record already has, `H178` for an earlier date, `H467` for an approval older than three business days, `H525` when the consent limit is reached, and the same `transactionId` for a request repeated with the same body, as for two movements of one address and type in the same second;
    * `POST /v2/.../consents/request` and `GET /v2/.../consents/request/{requestId}`: at most 1000 consents, `202` with a `requestId`, an empty status list until 300 seconds passed, then `success`, `failure` with the error code, per item;
    * `POST /sps/.../consents/status`, `GET /sps/.../consents/changes` (the last seven days without the last hour, `after`, `limit`, `source`), `GET /sps/{iysCode}/brands`, `GET /integrator/{integratorCode}/sps/{iysCode}` and `GET /sps/{iysCode}/subscription`;
    * `X-Trace-Id` on every answer; with `enforce_rates: true` the limit of 10 requests a second (`429 H124`) and of 1000 status requests an hour (`429 H086`).

  Not verified against the real service, because the document does not say: the answer of the status operation for a recipient İYS holds no record of (the fake answers `204`), the shape of the brand list (the fake answers a list) and the weekday-only count of the three business days.

  A test steers it with `advance/2` (the fake's clock), `fail_next/4` (the next call of an operation answers a given status and code), `put/3` and reads it with `get/2`, `consents/1` and `calls/1`.
  """

  use Boundary, top_level?: true, deps: [], exports: []

  use Agent

  import Plug.Conn

  @behaviour Plug

  @types ~w(ARAMA MESAJ EPOSTA)
  @statuses ~w(ONAY RET)
  @recipient_types ~w(BIREYSEL TACIR)
  @sources ~w(HS_FIZIKSEL_ORTAM HS_ISLAK_IMZA HS_WEB HS_CAGRI_MERKEZI HS_SOSYAL_MEDYA HS_EPOSTA
              HS_MESAJ HS_MOBIL HS_EORTAM HS_ETKINLIK HS_2015 HS_ATM HS_KARAR)
  @phone ~r/\A\+[1-9][0-9]{6,14}\z/
  @email ~r/\A[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}\z/
  @tr_offset_s 10_800

  @doc "Starts the fake. Options: `:name` (default `RelayTest.IysFake`), `:iys_code`, `:integrator_code`, `:username`, `:password`, `:brands` (a list of brand codes), `:authorisations`, `:subscription`, `:enforce_rates`, `:token_limit`."
  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    Agent.start_link(fn -> initial(opts) end, name: name)
  end

  @doc "A child specification; with `:port` the fake is also served over HTTP by Bandit."
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    case Keyword.pop(opts, :port) do
      {nil, opts} ->
        %{id: Keyword.get(opts, :name, __MODULE__), start: {__MODULE__, :start_link, [opts]}}

      {port, opts} ->
        name = Keyword.get(opts, :name, __MODULE__)
        children = [%{id: name, start: {__MODULE__, :start_link, [opts]}}, bandit(name, port)]
        %{id: {name, :http}, start: {Supervisor, :start_link, [children, [strategy: :one_for_one]]}}
    end
  end

  defp bandit(name, port),
    do: {Bandit, plug: {__MODULE__, server: name}, port: port, ip: :loopback}

  defp initial(opts) do
    brands = Keyword.get(opts, :brands, [9001])

    %{
      iys_code: Keyword.get(opts, :iys_code, 600_001),
      integrator_code: Keyword.get(opts, :integrator_code, 700_001),
      username: Keyword.get(opts, :username, "iys-user"),
      password: Keyword.get(opts, :password, "iys-password"),
      brands: brands,
      authorisations:
        Keyword.get(
          opts,
          :authorisations,
          Map.new(brands, &{&1, %{"MESAJ" => "write", "ARAMA" => "write", "EPOSTA" => "write"}})
        ),
      subscription:
        Keyword.get(opts, :subscription, %{
          "startDate" => "2026-01-01 00:00:00",
          "expirationDate" => "2027-01-01 00:00:00",
          "subscriptionPackageName" => "fake",
          "subscriptionId" => "sub-1",
          "status" => "ACTIVE",
          "consentLimit" => 1000,
          "usedConsentLimit" => 0,
          "consentLimitExceed" => false
        }),
      enforce_rates: Keyword.get(opts, :enforce_rates, false),
      token_limit: Keyword.get(opts, :token_limit, 100),
      token_requests: 0,
      access: %{},
      refresh: %{},
      consents: %{},
      movements: [],
      replies: %{},
      batches: %{},
      faults: [],
      calls: [],
      windows: %{},
      offset_s: 0,
      frozen_at: nil,
      counter: 0
    }
  end

  @doc "Moves the fake's clock forward by `seconds`."
  @spec advance(Agent.agent(), integer()) :: :ok
  def advance(server \\ __MODULE__, seconds),
    do: Agent.update(server, &%{&1 | offset_s: &1.offset_s + seconds})

  @doc "Stops the fake's clock at the current second, so that only `advance/2` moves it."
  @spec freeze(Agent.agent()) :: :ok
  def freeze(server \\ __MODULE__),
    do: Agent.update(server, &%{&1 | frozen_at: System.os_time(:second)})

  @doc "Makes the next call of `operation` (`:token`, `:add`, `:batch`, `:batch_status`, `:status`, `:changes`, `:brands`, `:authorisations` or `:subscription`) answer `status` with the İYS error `code`."
  @spec fail_next(Agent.agent(), atom(), pos_integer(), String.t() | nil) :: :ok
  def fail_next(server \\ __MODULE__, operation, status, code),
    do: Agent.update(server, &%{&1 | faults: &1.faults ++ [{operation, status, code}]})

  @doc "Replaces a field of the fake's state (`:subscription`, `:authorisations`, `:brands`, `:enforce_rates`, `:token_limit`)."
  @spec put(Agent.agent(), atom(), term()) :: :ok
  def put(server \\ __MODULE__, key, value), do: Agent.update(server, &Map.put(&1, key, value))

  @doc "Reads a field of the fake's state."
  @spec get(Agent.agent(), atom()) :: term()
  def get(server \\ __MODULE__, key), do: Agent.get(server, &Map.get(&1, key))

  @doc "The consents the fake holds, by `{brand_code, recipient, type, recipient_type}`."
  @spec consents(Agent.agent()) :: map()
  def consents(server \\ __MODULE__), do: Agent.get(server, & &1.consents)

  @doc "The calls the fake answered, oldest first: `{operation, status}`."
  @spec calls(Agent.agent()) :: [{atom(), pos_integer()}]
  def calls(server \\ __MODULE__), do: Agent.get(server, &Enum.reverse(&1.calls))

  @doc "Records a movement the recipient made at İYS itself (source `IYS_WEB`), as the pull operation reports it."
  @spec citizen(Agent.agent(), pos_integer(), map()) :: :ok
  def citizen(server \\ __MODULE__, brand_code, %{} = consent) do
    Agent.update(server, fn state ->
      consent = Map.merge(%{"recipientType" => "BIREYSEL", "source" => "IYS_WEB"}, consent)
      consent = Map.put_new(consent, "consentDate", format(now(state)))
      {_reply, state} = store(state, brand_code, consent)
      state
    end)
  end

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, opts) do
    server = Keyword.get(opts, :server, __MODULE__)
    {:ok, raw, conn} = read_body(conn)
    request = %{method: conn.method, path: conn.path_info, query: query(conn), body: body(conn, raw)}
    request = Map.put(request, :token, bearer(conn))

    {status, payload} =
      try do
        Agent.get_and_update(server, &answer(&1, request))
      catch
        :exit, _reason -> {503, errors("H192", "the fake is not running")}
      end

    conn
    |> put_resp_header("x-trace-id", Base.encode16(:crypto.strong_rand_bytes(16), case: :lower))
    |> respond(status, payload)
  end

  defp respond(conn, 204, _payload), do: send_resp(conn, 204, "")

  defp respond(conn, status, payload) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(payload))
  end

  defp query(conn), do: conn |> fetch_query_params() |> Map.get(:query_params)

  defp body(_conn, ""), do: nil

  defp body(conn, raw) do
    form? = conn |> get_req_header("content-type") |> Enum.any?(&(&1 =~ "x-www-form-urlencoded"))

    cond do
      form? -> URI.decode_query(raw)
      true -> decoded(Jason.decode(raw))
    end
  end

  defp decoded({:ok, value}), do: value
  defp decoded({:error, _error}), do: :invalid

  defp bearer(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token | _rest] -> token
      _other -> nil
    end
  end

  defp answer(state, request) do
    operation = operation(request)

    {reply, state} =
      case fault(state, operation) do
        {{status, code}, state} -> {{status, errors(code, "injected")}, state}
        {nil, state} -> guarded(state, operation, request)
      end

    {status, _payload} = reply
    {reply, %{state | calls: [{operation, status} | state.calls]}}
  end

  defp operation(%{method: "POST", path: ["oauth2", "token"]}), do: :token
  defp operation(%{method: "GET", path: ["sps", _iys, "brands"]}), do: :brands
  defp operation(%{method: "GET", path: ["sps", _iys, "subscription"]}), do: :subscription
  defp operation(%{method: "GET", path: ["integrator", _code, "sps", _iys]}), do: :authorisations

  defp operation(%{method: "POST", path: ["v2", "sps", _iys, "brands", _brand, "consents"]}),
    do: :add

  defp operation(%{
         method: "POST",
         path: ["v2", "sps", _iys, "brands", _brand, "consents", "request"]
       }),
       do: :batch

  defp operation(%{
         method: "GET",
         path: ["v2", "sps", _iys, "brands", _brand, "consents", "request", _id]
       }),
       do: :batch_status

  defp operation(%{method: "POST", path: ["sps", _iys, "brands", _brand, "consents", "status"]}),
    do: :status

  defp operation(%{method: "GET", path: ["sps", _iys, "brands", _brand, "consents", "changes"]}),
    do: :changes

  defp operation(_request), do: :unknown

  defp fault(state, operation) do
    case Enum.split_with(state.faults, fn {name, _status, _code} -> name == operation end) do
      {[{_name, status, code} | later], others} ->
        {{status, code}, %{state | faults: later ++ others}}

      {[], _others} ->
        {nil, state}
    end
  end

  defp guarded(state, :unknown, _request), do: {{404, errors("H015", "unknown operation")}, state}
  defp guarded(state, :token, request), do: token(state, request.body)

  defp guarded(state, operation, request) do
    with :ok <- authenticated(state, request.token),
         :ok <- owned(state, request.path),
         {:ok, state} <- within_rates(state, operation) do
      handle(state, operation, request)
    else
      {:error, reply, state} -> {reply, state}
      {:error, reply} -> {reply, state}
    end
  end

  defp authenticated(state, token) do
    case Map.get(state.access, token) do
      until when is_integer(until) ->
        if until > seconds(state), do: :ok, else: {:error, {401, errors("H351", "invalid token")}}

      nil ->
        {:error, {401, errors("H351", "invalid token")}}
    end
  end

  defp owned(state, ["integrator", code, "sps", iys]) do
    if code == Integer.to_string(state.integrator_code) and iys == Integer.to_string(state.iys_code),
      do: :ok,
      else: {:error, {403, errors("H353", "not authorised")}}
  end

  defp owned(state, path) do
    iys = path |> Enum.drop_while(&(&1 != "sps")) |> Enum.at(1)

    if iys == Integer.to_string(state.iys_code),
      do: :ok,
      else: {:error, {403, errors("H353", "not authorised")}}
  end

  defp within_rates(%{enforce_rates: false} = state, _operation), do: {:ok, state}

  defp within_rates(state, operation) do
    with {:ok, state} <- window(state, :second, seconds(state), 10, "H124") do
      if operation == :status,
        do: window(state, :status_hour, div(seconds(state), 3600), 1000, "H086"),
        else: {:ok, state}
    end
  end

  defp window(state, name, slot, limit, code) do
    {current, count} = Map.get(state.windows, name, {slot, 0})
    count = if current == slot, do: count + 1, else: 1
    state = %{state | windows: Map.put(state.windows, name, {slot, count})}

    if count > limit,
      do: {:error, {429, errors(code, "limit reached")}, state},
      else: {:ok, state}
  end

  defp token(state, body) when not is_map(body),
    do: {{400, %{"error" => "invalid_request", "error_description" => "no body"}}, state}

  defp token(%{token_requests: requests, token_limit: limit} = state, _body)
       when requests >= limit,
       do: {{429, errors("H084", "hourly token limit")}, state}

  defp token(state, %{"grant_type" => "password"} = body) do
    state = %{state | token_requests: state.token_requests + 1}

    if body["username"] == state.username and body["password"] == state.password,
      do: issue(state),
      else: {{401, errors("H251", "invalid credentials")}, state}
  end

  defp token(state, %{"grant_type" => "refresh_token", "refresh_token" => refresh}) do
    state = %{state | token_requests: state.token_requests + 1}

    case Map.pop(state.refresh, refresh) do
      {until, rest} when is_integer(until) ->
        if until > seconds(state),
          do: issue(%{state | refresh: rest}),
          else: {{401, errors("H251", "refresh token expired")}, state}

      {nil, _rest} ->
        {{401, errors("H251", "unknown refresh token")}, state}
    end
  end

  defp token(state, _body),
    do: {{400, %{"error" => "invalid_request", "error_description" => "grant_type"}}, state}

  defp issue(state) do
    {access, state} = unique(state, "access")
    {refresh, state} = unique(state, "refresh")
    now = seconds(state)

    state = %{
      state
      | access: Map.put(state.access, access, now + 7200),
        refresh: Map.put(state.refresh, refresh, now + 14_400)
    }

    reply = %{
      "access_token" => access,
      "refresh_token" => refresh,
      "expires_in" => 7200,
      "refresh_expires_in" => 14_400,
      "token_type" => "bearer"
    }

    {{200, reply}, state}
  end

  defp unique(state, prefix) do
    counter = state.counter + 1
    {prefix <> "-" <> Integer.to_string(counter), %{state | counter: counter}}
  end

  defp handle(state, :brands, _request) do
    list = for code <- state.brands, do: %{"brandCode" => code, "name" => "Brand", "master" => true}
    {{200, list}, state}
  end

  defp handle(state, :subscription, _request), do: {{200, state.subscription}, state}

  defp handle(state, :authorisations, request) do
    offset = integer(request.query["offset"]) || 0
    limit = integer(request.query["limit"]) || 100

    all =
      for {code, access} <- Enum.sort(state.authorisations) do
        Map.merge(access, %{
          "brandCode" => Integer.to_string(code),
          "iysCode" => Integer.to_string(state.iys_code),
          "name" => "Brand",
          "master" => true,
          "agreementControl" => true,
          "viaControl" => false
        })
      end

    page = all |> Enum.drop(offset) |> Enum.take(limit)
    pagination = %{"offset" => offset, "pageSize" => length(page), "totalCount" => length(all)}
    {{200, %{"pagination" => pagination, "list" => page}}, state}
  end

  defp handle(state, :add, %{body: body, path: path}) when is_map(body) do
    brand = brand(path)
    key = {brand, body}

    case Map.fetch(state.replies, key) do
      {:ok, reply} ->
        {{200, reply}, state}

      :error ->
        with :ok <- valid(state, body),
             :ok <- transition(state, brand, body) do
          {reply, state} = store(state, brand, body)
          {{200, reply}, %{state | replies: Map.put(state.replies, key, reply)}}
        else
          {:error, reply} -> {reply, state}
        end
    end
  end

  defp handle(state, :add, _request), do: {{400, errors("H014", "not JSON")}, state}

  defp handle(state, :batch, %{body: list, path: path}) when is_list(list) do
    keys = Enum.map(list, &{&1["recipient"], &1["type"], &1["recipientType"] || "BIREYSEL"})

    cond do
      list == [] ->
        {{400, errors("H092", "empty request")}, state}

      length(list) > 1000 ->
        {{422, field_errors("H125", [], "at most 1000")}, state}

      length(Enum.uniq(keys)) != length(keys) ->
        {{422, field_errors("H194", ["recipient"], "repeated")}, state}

      true ->
        {id, state} = unique(state, "request")
        batch = %{brand: brand(path), items: list, at: seconds(state), results: nil}
        subs = for {item, index} <- Enum.with_index(list), do: Map.put(item, "subrequestId", sub(id, index))
        reply = %{"requestId" => id, "subRequests" => subs}
        {{202, reply}, %{state | batches: Map.put(state.batches, id, batch)}}
    end
  end

  defp handle(state, :batch, _request), do: {{400, errors("H092", "not a list")}, state}

  defp handle(state, :batch_status, %{path: path}) do
    id = List.last(path)

    case Map.get(state.batches, id) do
      nil ->
        {{200, []}, state}

      %{results: results} when is_list(results) ->
        {{200, results}, state}

      %{at: at} = batch ->
        if seconds(state) - at < 300, do: {{200, []}, state}, else: processed(state, id, batch)
    end
  end

  defp handle(state, :status, %{body: %{"recipient" => recipient, "type" => type} = body, path: path}) do
    key = {brand(path), normal(type, recipient), type, body["recipientType"] || "BIREYSEL"}

    case Map.get(state.consents, key) do
      nil -> {{204, nil}, state}
      consent -> {{200, consent}, state}
    end
  end

  defp handle(state, :status, _request), do: {{400, errors("H403", "invalid request")}, state}

  defp handle(state, :changes, %{query: query, path: path}) do
    brand = brand(path)
    source = Map.get(query, "source", "IYS")
    limit = min(integer(query["limit"]) || 1000, 1000)
    now = seconds(state)

    visible =
      state.movements
      |> Enum.reverse()
      |> Enum.filter(fn movement ->
        movement.brand == brand and movement.at <= now - 3600 and movement.at >= now - 7 * 86_400 and
          String.starts_with?(movement.consent["source"], source)
      end)

    rest =
      case query["after"] do
        nil -> visible
        cursor -> visible |> Enum.drop_while(&(&1.cursor != cursor)) |> Enum.drop(1)
      end

    case Enum.take(rest, limit) do
      [] ->
        {{204, nil}, state}

      page ->
        reply = %{"after" => List.last(page).cursor, "list" => Enum.map(page, & &1.consent)}
        {{200, reply}, state}
    end
  end

  defp processed(state, id, batch) do
    {results, state} =
      batch.items
      |> Enum.with_index()
      |> Enum.map_reduce(state, fn {item, index}, state ->
        base = %{"index" => index, "subRequestId" => sub(id, index), "requestId" => id}

        with :ok <- valid(state, item),
             :ok <- transition(state, batch.brand, item) do
          {reply, state} = store(state, batch.brand, item)
          {Map.merge(base, Map.put(reply, "status", "success")), state}
        else
          {:error, {_status, %{"errors" => [error | _rest]}}} ->
            failure = Map.take(error, ["code", "message"])
            {Map.merge(base, %{"status" => "failure", "error" => failure}), state}
        end
      end)

    {{200, results}, %{state | batches: Map.put(state.batches, id, %{batch | results: results})}}
  end

  defp sub(id, index), do: id <> "-" <> Integer.to_string(index)

  defp valid(state, body) do
    checks = [
      &required/2,
      &enumerated/2,
      &recipient/2,
      &dated/2,
      &decision/2
    ]

    Enum.reduce_while(checks, :ok, fn check, :ok ->
      case check.(state, body) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp required(_state, body) do
    missing = [
      {"type", "H111"},
      {"source", "H113"},
      {"recipient", "H114"},
      {"status", "H110"},
      {"consentDate", "H112"}
    ]

    case Enum.find(missing, fn {name, _code} -> body[name] in [nil, ""] end) do
      nil -> :ok
      {name, code} -> {:error, {422, field_errors(code, [name], "missing")}}
    end
  end

  defp enumerated(_state, body) do
    cond do
      body["type"] not in @types -> invalid("H117", "type")
      body["status"] not in @statuses -> invalid("H115", "status")
      (body["recipientType"] || "BIREYSEL") not in @recipient_types -> invalid("H116", "recipientType")
      body["source"] not in @sources -> invalid("H119", "source")
      true -> :ok
    end
  end

  defp recipient(_state, %{"type" => "EPOSTA", "recipient" => recipient}) do
    size = String.length(recipient)

    if size >= 6 and size <= 265 and Regex.match?(@email, String.downcase(recipient)),
      do: :ok,
      else: invalid("H120", "recipient")
  end

  defp recipient(_state, %{"recipient" => recipient}) do
    cond do
      String.length(recipient) > 15 -> invalid("H160", "recipient")
      not Regex.match?(@phone, recipient) -> invalid("H121", "recipient")
      true -> :ok
    end
  end

  defp dated(state, %{"consentDate" => text} = body) do
    case parse(text) do
      nil ->
        invalid("H158", "consentDate")

      at ->
        cond do
          at > seconds(state) + 5 -> invalid("H162", "consentDate")
          at < parse("2015-05-01 00:00:00") -> invalid("H156", "consentDate")
          body["status"] == "ONAY" and stale?(state, at) -> invalid("H467", "consentDate")
          true -> :ok
        end
    end
  end

  defp stale?(state, at) do
    first = Date.add(~D[1970-01-01], div(at + @tr_offset_s, 86_400))
    today = Date.add(~D[1970-01-01], div(seconds(state) + @tr_offset_s, 86_400))
    Date.compare(today, first) == :gt and
      Enum.count(Date.range(Date.add(first, 1), today), &(Date.day_of_week(&1) < 6)) > 3
  end

  defp decision(_state, %{"source" => "HS_KARAR", "status" => "ONAY"}), do: invalid("H408", "source")
  defp decision(_state, _body), do: :ok

  defp invalid(code, name), do: {:error, {422, field_errors(code, [name], "invalid")}}

  defp transition(state, brand, body) do
    key = key(brand, body)
    full? = full?(state.subscription)
    status = body["status"]

    case Map.get(state.consents, key) do
      nil when status == "RET" ->
        {:error, {400, errors("H175", "a first record cannot be RET")}}

      nil when full? ->
        {:error, {422, field_errors("H525", [], "consent limit reached")}}

      nil ->
        :ok

      %{"status" => ^status} ->
        {:error, {400, errors("H174", "the consent already has this status")}}

      %{"consentDate" => held} ->
        if parse(body["consentDate"]) < parse(held),
          do: {:error, {400, errors("H178", "an earlier date")}},
          else: :ok
    end
  end

  defp full?(%{"consentLimit" => limit, "usedConsentLimit" => used} = subscription),
    do: used >= limit and subscription["consentLimitExceed"] != true

  defp store(state, brand, body) do
    key = key(brand, body)
    {_brand, recipient, type, recipient_type} = key
    at = seconds(state)
    created = format(at)
    seed = Enum.join([brand, recipient, type, created], "|")
    transaction = Base.encode16(:crypto.hash(:sha256, seed), case: :lower)

    consent = %{
      "recipient" => recipient,
      "type" => type,
      "recipientType" => recipient_type,
      "status" => body["status"],
      "source" => body["source"],
      "consentDate" => body["consentDate"],
      "creationDate" => created,
      "transactionId" => transaction
    }

    new? = not Map.has_key?(state.consents, key)
    used = state.subscription["usedConsentLimit"] + if(new?, do: 1, else: 0)
    movement = %{brand: brand, at: at, cursor: created <> "|" <> transaction, consent: consent}

    state = %{
      state
      | consents: Map.put(state.consents, key, consent),
        movements: [movement | state.movements],
        subscription: Map.put(state.subscription, "usedConsentLimit", used)
    }

    {%{"transactionId" => transaction, "creationDate" => created}, state}
  end

  defp key(brand, body) do
    type = body["type"]
    {brand, normal(type, body["recipient"]), type, body["recipientType"] || "BIREYSEL"}
  end

  defp normal("EPOSTA", recipient), do: String.downcase(recipient)
  defp normal(_type, recipient), do: recipient

  defp brand(path) do
    path |> Enum.drop_while(&(&1 != "brands")) |> Enum.at(1) |> integer()
  end

  defp errors(code, message), do: %{"errors" => [%{"code" => code, "message" => message}]}

  defp field_errors(code, location, message),
    do: %{"errors" => [%{"code" => code, "location" => location, "message" => message}]}

  defp now(state), do: seconds(state)

  defp seconds(state), do: (state.frozen_at || System.os_time(:second)) + state.offset_s

  defp format(seconds) do
    (seconds + @tr_offset_s)
    |> DateTime.from_unix!()
    |> Calendar.strftime("%Y-%m-%d %H:%M:%S")
  end

  defp parse(<<date::binary-size(10), " ", time::binary-size(8)>>) do
    with {:ok, day} <- Date.from_iso8601(date),
         {:ok, clock} <- Time.from_iso8601(time),
         {:ok, naive} <- NaiveDateTime.new(day, clock) do
      DateTime.to_unix(DateTime.from_naive!(naive, "Etc/UTC")) - @tr_offset_s
    else
      _invalid -> nil
    end
  end

  defp parse(_other), do: nil

  defp integer(value) when is_integer(value), do: value

  defp integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} -> number
      _other -> nil
    end
  end

  defp integer(_other), do: nil
end
