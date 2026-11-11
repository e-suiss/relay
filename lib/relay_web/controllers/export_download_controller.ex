defmodule RelayWeb.ExportDownloadController do
  @moduledoc """
  The signed download link of a raw data export (DS-37). The link needs no credential: its token is the authority, it names one export of one tenant environment and expires with it. A valid link answers the CSV as an attachment and is audited; an unknown or forged token is `404`, an expired link or export `410`, and the key store or database being unreachable `503`. Nothing is cached and the link is never sent on as a referrer.
  """

  use RelayWeb, :controller

  # DS-37
  # TN-18
  @doc "Answers the export behind a signed download token."
  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, %{"token" => token}) do
    case Relay.Api.Exports.download(token) do
      {:ok, {filename, content}} ->
        conn
        |> put_resp_content_type("text/csv")
        |> put_resp_header("content-disposition", ~s(attachment; filename="#{filename}"))
        |> send_resp(200, content)

      {:error, :not_found} ->
        send_resp(conn, 404, "")

      {:error, :gone} ->
        send_resp(conn, 410, "")

      {:error, _unavailable} ->
        conn |> put_resp_header("retry-after", "1") |> send_resp(503, "")
    end
  end
end
