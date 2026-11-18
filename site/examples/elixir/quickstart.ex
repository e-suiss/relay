defmodule DocsExamples.Quickstart do
  @moduledoc false

  def run do
    # #region quickstart
    credentials =
      EsuissRelay.Credentials.AccessClient.new(
        token_endpoint: "https://access.example.com/oauth2/token",
        client_id: System.fetch_env!("ACCESS_CLIENT_ID"),
        client_secret: System.fetch_env!("ACCESS_CLIENT_SECRET"),
        resource: System.fetch_env!("RELAY_ACCESS_CLIENT_ID")
      )

    client = EsuissRelay.new(base_url: "https://relay.example.com", credentials: credentials)

    {:ok, event} =
      EsuissRelay.Api.create_event(client, %{
        "workflow" => "welcome",
        "to" => [%{"id" => "user-4821", "email" => "ayse@example.com"}],
        "data" => %{"first_name" => "Ayşe"}
      })

    IO.puts(event["id"])
    # #endregion quickstart

    # #region decisions
    {:ok, page} = EsuissRelay.Api.list_subscriber_decisions(client, "user-4821", limit: 50)

    for decision <- page, delivery <- decision["deliveries"] do
      IO.puts("#{decision["notification_id"]} #{delivery["channel"]} #{delivery["status"]}")
    end
    # #endregion decisions

    # #region errors
    case EsuissRelay.Api.create_event(client, %{"workflow" => "welcome"},
           idempotency_key: "order:4821:shipped"
         ) do
      {:ok, accepted} -> accepted
      {:error, %EsuissRelay.ValidationError{problem: problem}} -> {:invalid, problem["errors"]}
      {:error, %EsuissRelay.QuotaError{}} -> :quota_exhausted
      {:error, error} -> raise error
    end
    # #endregion errors
  end
end
