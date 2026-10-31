defmodule RelayWeb.Operator.SessionController do
  @moduledoc false

  use RelayWeb, :api_controller

  import RelayWeb.Operator.Helpers

  alias Relay.Operators
  alias Relay.Operators.Access
  alias RelayWeb.Api.Response
  alias RelayWeb.Operator.Json
  alias RelayWeb.Operator.Pipeline

  @login_cookie "relay_operator_login"
  @step_up_cookie "relay_operator_step_up"
  @flow_s 600
  @session_s 43_200
  @return_to ~r/\A\/[^\/][^\s]{0,510}\z/

  # E-26
  # TN-19
  @spec login(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def login(conn, params) do
    with {:ok, return_to} <- return_to(params["return_to"]),
         flow = Operators.login_parameters(),
         {:ok, url} <- Access.authorization_url(authorize(flow, callback_uri("callback"))) do
      conn
      |> put_flow(@login_cookie, flow, return_to)
      |> redirect_to(url)
    else
      {:error, error} -> problem(conn, error)
    end
  end

  # E-26
  # TN-19
  # E-63
  @spec callback(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def callback(conn, params) do
    with {:ok, code, state} <- code_and_state(params),
         {:ok, flow} <- flow(conn, @login_cookie, state),
         {:ok, %{token: token}} <-
           Operators.complete_login(code, flow, callback_uri("callback"), &csrf(conn, &1)) do
      conn
      |> delete_resp_cookie(@login_cookie, cookie_options(:lax))
      |> put_resp_cookie(
        Pipeline.cookie(),
        token,
        Keyword.put(cookie_options(:strict), :max_age, @session_s)
      )
      |> redirect_to(flow["return_to"] || "/")
    else
      {:error, %Relay.Error{code: :auth_invalid_session}} ->
        problem(conn, Relay.Error.new(:auth_invalid_token, "the operator is not active"))

      {:error, error} ->
        problem(conn, error)
    end
  end

  # X-3
  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, _params) do
    session = conn.assigns.operator_session
    reply(conn, 200, Json.session(session, csrf(conn, credential(conn))))
  end

  @spec delete(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def delete(conn, _params) do
    :ok = Operators.sign_out(conn.assigns.operator_session)

    conn
    |> delete_resp_cookie(Pipeline.cookie(), cookie_options(:strict))
    |> send_resp(204, "")
  end

  # TN-21
  # E-27
  @spec start_step_up(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def start_step_up(conn, _params) do
    body = conn.assigns.body || %{}
    flow = Operators.login_parameters()

    params =
      flow
      |> authorize(callback_uri("step_up/callback"))
      |> Map.merge(%{acr_values: Access.step_up_acr(), max_age: 0, prompt: "login"})

    case Access.authorization_url(params) do
      {:ok, url} ->
        expires_at = DateTime.add(Relay.Clock.utc_now(), @flow_s, :second)

        conn
        |> put_flow(@step_up_cookie, flow, body["return_to"])
        |> reply(200, %{
          "object" => "step_up_challenge",
          "authorization_url" => url,
          "expires_at" => Json.time(expires_at)
        })

      {:error, error} ->
        problem(conn, error)
    end
  end

  # TN-21
  # E-27
  @spec complete_step_up(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def complete_step_up(conn, params) do
    session = conn.assigns.operator_session

    with {:ok, code, state} <- code_and_state(params),
         {:ok, flow} <- flow(conn, @step_up_cookie, state),
         :ok <- Operators.complete_step_up(session, code, flow, callback_uri("step_up/callback")) do
      conn
      |> delete_resp_cookie(@step_up_cookie, cookie_options(:lax))
      |> redirect_to(flow["return_to"] || "/")
    else
      {:error, error} -> problem(conn, error)
    end
  end

  defp authorize(flow, redirect_uri) do
    %{
      state: flow.state,
      nonce: flow.nonce,
      code_challenge: flow.challenge,
      redirect_uri: redirect_uri
    }
  end

  defp callback_uri(path), do: Response.base_url() <> "/v1/operator/session/" <> path

  defp return_to(nil), do: {:ok, nil}

  defp return_to(value) when is_binary(value) do
    if Regex.match?(@return_to, value),
      do: {:ok, value},
      else: {:error, field("/query/return_to", "invalid_format", "a panel path")}
  end

  defp return_to(_value), do: {:error, field("/query/return_to", "invalid_format", "a path")}

  defp code_and_state(%{"code" => code, "state" => state})
       when is_binary(code) and is_binary(state) and byte_size(code) <= 2048 and
              byte_size(state) <= 512,
       do: {:ok, code, state}

  defp code_and_state(_params),
    do: {:error, field("/query/code", "required", "code and state are required")}

  defp put_flow(conn, name, flow, return_to) do
    value = %{
      "state" => flow.state,
      "nonce" => flow.nonce,
      "verifier" => flow.verifier,
      "return_to" => return_to
    }

    token = Plug.Crypto.encrypt(conn.secret_key_base, name, value, max_age: @flow_s)
    put_resp_cookie(conn, name, token, Keyword.put(cookie_options(:lax), :max_age, @flow_s))
  end

  defp flow(conn, name, state) do
    with token when is_binary(token) <- conn.req_cookies[name],
         {:ok, %{"state" => expected} = flow} <-
           Plug.Crypto.decrypt(conn.secret_key_base, name, token, max_age: @flow_s),
         true <- Plug.Crypto.secure_compare(expected, state) do
      {:ok, Map.merge(flow, %{verifier: flow["verifier"], nonce: flow["nonce"]})}
    else
      _ -> {:error, Relay.Error.new(:auth_invalid_token, "the sign-in flow is not valid")}
    end
  end

  defp redirect_to(conn, location) do
    conn
    |> put_resp_header("location", location)
    |> send_resp(302, "")
  end

  defp cookie_options(:strict),
    do: [http_only: true, secure: true, same_site: "Strict", path: "/"]

  defp cookie_options(:lax),
    do: [http_only: true, secure: true, same_site: "Lax", path: "/v1/operator/session"]

  defp credential(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> token
      ["bearer " <> token] -> token
      _ -> conn.req_cookies[Pipeline.cookie()] || ""
    end
  end

  defp csrf(conn, token) do
    conn.secret_key_base
    |> Relay.Crypto.hmac_sha256("relay operator csrf " <> token)
    |> Base.url_encode64(padding: false)
  end
end
