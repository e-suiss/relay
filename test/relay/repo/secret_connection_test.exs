defmodule Relay.Repo.SecretConnectionTest do
  use ExUnit.Case, async: false

  alias Relay.Config.SecretFiles

  @moduletag :integration
  @moduletag :tmp_dir

  @password "relay"

  defp connection_pids(before) do
    for pid <- Process.list() -- before,
        Process.info(pid, :initial_call) == {:initial_call, {:proc_lib, :init_p, 5}},
        {:status, ^pid, _, [pdict | _]} <- [status(pid)],
        Keyword.get(pdict, :"$initial_call") == {DBConnection.Connection, :init, 1},
        do: pid
  end

  defp status(pid) do
    :sys.get_status(pid, 1_000)
  catch
    :exit, _ -> nil
  end

  defp holds_password?(term) do
    case term do
      @password -> true
      {:password, _} -> true
      %_{} = struct -> struct |> Map.from_struct() |> holds_password?()
      %{} = map -> Enum.any?(map, &holds_password?/1)
      list when is_list(list) -> Enum.any?(list, &holds_password?/1)
      tuple when is_tuple(tuple) -> tuple |> Tuple.to_list() |> holds_password?()
      _ -> false
    end
  end

  test "TN-67: a database connection takes its password from the file at connect time and runs as a sensitive process",
       %{tmp_dir: dir} do
    path = Path.join(dir, "database-password")
    File.write!(path, @password <> "\n")
    previous = :sys.replace_state(SecretFiles, fn _ -> %{repo: path} end)

    try do
      opts =
        :relay
        |> Application.fetch_env!(Relay.Repo)
        |> Keyword.take([:hostname, :port, :database, :username, :socket_dir, :ssl])
        |> Keyword.merge(pool_size: 1, configure: {SecretFiles, :configure, [:repo]})

      before = Process.list()
      {:ok, conn} = Postgrex.start_link(opts)
      assert %Postgrex.Result{rows: [[1]]} = Postgrex.query!(conn, "SELECT 1", [])

      assert [pid] = connection_pids(before)
      assert Process.info(pid, :dictionary) == {:dictionary, []}
      refute holds_password?(:sys.get_status(pid))
      refute holds_password?(opts)

      GenServer.stop(conn)
    after
      :sys.replace_state(SecretFiles, fn _ -> previous end)
    end
  end
end
