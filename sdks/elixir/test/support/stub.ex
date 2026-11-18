defmodule EsuissRelay.Stub do
  @moduledoc false

  @behaviour EsuissRelay.Transport

  alias EsuissRelay.Client
  alias EsuissRelay.Credentials.Static
  alias EsuissRelay.DpopKey

  def start(responses) do
    {:ok, pid} = Agent.start_link(fn -> %{responses: responses, requests: []} end)
    pid
  end

  def client(responses, opts \\ []) do
    stub = start(responses)
    test = self()

    client =
      Client.new(
        Keyword.merge(
          [
            base_url: "https://relay.test",
            credentials: Static.new("token-1", DpopKey.from_seed(:binary.copy(<<7>>, 32))),
            transport: {__MODULE__, stub},
            sleep: fn ms -> send(test, {:slept, ms}) end,
            random: fn max -> max end,
            clock: fn -> 1_800_000_000 end
          ],
          opts
        )
      )

    {client, stub}
  end

  def requests(stub), do: Agent.get(stub, &Enum.reverse(&1.requests))

  def json(status, body, headers \\ []),
    do: {:ok, %{status: status, headers: headers, body: JSON.encode!(body)}}

  @impl true
  def request(stub, request) do
    Agent.get_and_update(stub, fn state ->
      state = %{state | requests: [request | state.requests]}

      case state.responses do
        [next | rest] -> {answer(next, request), %{state | responses: rest}}
        [] -> {{:error, :no_more_responses}, state}
      end
    end)
  end

  defp answer(fun, request) when is_function(fun, 1), do: fun.(request)
  defp answer(response, _request), do: response
end
