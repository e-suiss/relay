defmodule Relay.Parquet.Port do
  @moduledoc """
  `Relay.Parquet` implementation on the `archive_port` program. Every call verifies the program against its SHA-256, starts it as a fresh OS process for that one file and closes it when the call returns, so a crash or a stuck program ends only that call. Rows go to the program in frames of at most 1 000 rows or 4 MiB.

  Options: `:executable` (default the program bundled in the release), `:sha256` (default the checksum embedded at compile time) and `:timeout` in milliseconds for each request (default 60 000).

  Errors carry the codes `:parquet_bad_request`, `:parquet_too_large`, `:parquet_out_of_order`, `:parquet_io`, `:parquet_invalid`, `:parquet_encoding`, `:parquet_bad_row`, `:parquet_timeout`, `:parquet_unavailable` and `:parquet_integrity`.
  """

  @behaviour Relay.Parquet

  alias Relay.Error
  alias Relay.Parquet.Digest

  @version 1
  @batch_rows 1_000
  @batch_bytes 4 * 1024 * 1024
  @read_rows 1_000
  @default_timeout 60_000
  @program "priv/native/archive_port"
  @checksum_file Path.expand("../../../#{@program}.sha256", __DIR__)
  @external_resource @checksum_file
  @embedded_sha256 (with {:ok, content} <- File.read(@checksum_file),
                         [hash | _] <- String.split(content),
                         true <- hash =~ ~r/\A[0-9a-fA-F]{64}\z/ do
                      String.downcase(hash)
                    else
                      _ -> nil
                    end)

  @codes %{
    1 => :parquet_bad_request,
    2 => :parquet_bad_request,
    3 => :parquet_too_large,
    4 => :parquet_out_of_order,
    5 => :parquet_io,
    6 => :parquet_invalid,
    7 => :parquet_encoding
  }

  # OP-84
  @impl Relay.Parquet
  @doc "Writes the rows to a new Parquet file; see `Relay.Parquet.write/4`."
  @spec write(Path.t(), [String.t(), ...], Enumerable.t(), keyword()) ::
          {:ok, Relay.Parquet.summary()} | {:error, Error.t()}
  def write(path, [_ | _] = columns, rows, opts) do
    with {:ok, port, timeout} <- start(opts) do
      try do
        write_file(port, timeout, path, columns, rows)
      after
        close(port)
      end
    end
  end

  defp write_file(port, timeout, path, columns, rows) do
    with :ok <- call_ok(port, open_frame(path, columns), timeout),
         :ok <- send_rows(port, rows, length(columns), timeout),
         {:ok, frame} <- call(port, <<@version, 3>>, timeout) do
      summary(frame)
    end
  end

  # OP-84
  @impl Relay.Parquet
  @doc "Reads a Parquet file back; see `Relay.Parquet.verify/2`."
  @spec verify(Path.t(), keyword()) :: {:ok, Relay.Parquet.verified()} | {:error, Error.t()}
  def verify(path, opts) do
    with {:ok, port, timeout} <- start(opts) do
      try do
        verify_file(port, timeout, path)
      after
        close(port)
      end
    end
  end

  defp verify_file(port, timeout, path) do
    with {:ok, frame} <- call(port, path_frame(4, path), timeout),
         {:ok, summary, rest} <- split_summary(frame),
         {:ok, columns} <- columns(rest) do
      {:ok, Map.put(summary, :columns, columns)}
    end
  end

  # OP-84
  @impl Relay.Parquet
  @doc "Folds the rows of a Parquet file in batches; see `Relay.Parquet.reduce/4`."
  @spec reduce(Path.t(), acc, Relay.Parquet.reducer(acc), keyword()) ::
          {:ok, [String.t()], acc} | {:error, Error.t()}
        when acc: term()
  def reduce(path, acc, fun, opts) do
    with {:ok, port, timeout} <- start(opts) do
      try do
        reduce_file(port, timeout, path, acc, fun)
      after
        close(port)
      end
    end
  end

  defp reduce_file(port, timeout, path, acc, fun) do
    with {:ok, frame} <- call(port, path_frame(5, path), timeout),
         {:ok, columns} <- opened_columns(frame),
         {:ok, acc} <- read_batches(port, length(columns), acc, fun, timeout) do
      {:ok, columns, acc}
    end
  end

  defp opened_columns(<<@version, 0, rest::binary>>), do: columns(rest)

  defp read_batches(port, width, acc, fun, timeout) do
    case call(port, <<@version, 6, @read_rows::32>>, timeout) do
      {:ok, <<@version, 0, 0::32>>} ->
        {:ok, acc}

      {:ok, <<@version, 0, count::32, rows::binary>>} ->
        with {:ok, batch} <- decode_rows(rows, count, width),
             do: read_batches(port, width, fun.(batch, acc), fun, timeout)

      {:ok, _frame} ->
        malformed()

      {:error, _} = error ->
        error
    end
  end

  @doc "Decodes `count` rows of `width` values from their canonical encoding."
  @spec decode_rows(binary(), non_neg_integer(), pos_integer()) ::
          {:ok, [Relay.Parquet.row()]} | {:error, Error.t()}
  def decode_rows(binary, count, width), do: decode_rows(binary, count, width, [])

  defp decode_rows(<<>>, 0, _width, acc), do: {:ok, Enum.reverse(acc)}

  defp decode_rows(binary, count, width, acc) when count > 0 do
    case decode_values(binary, width, []) do
      {:ok, row, rest} -> decode_rows(rest, count - 1, width, [row | acc])
      :error -> malformed()
    end
  end

  defp decode_rows(_binary, _count, _width, _acc), do: malformed()

  defp decode_values(rest, 0, acc), do: {:ok, Enum.reverse(acc), rest}
  defp decode_values(<<0, rest::binary>>, n, acc), do: decode_values(rest, n - 1, [nil | acc])

  defp decode_values(<<1, len::32, value::binary-size(len), rest::binary>>, n, acc),
    do: decode_values(rest, n - 1, [value | acc])

  defp decode_values(_binary, _n, _acc), do: :error

  defp send_rows(port, rows, width, timeout) do
    rows
    |> Enum.reduce_while({:ok, 0, 0, []}, &push_row(&1, &2, port, width, timeout))
    |> case do
      {:ok, 0, _bytes, _frame} -> :ok
      {:ok, count, _bytes, frame} -> flush(port, count, frame, timeout)
      {:error, _} = error -> error
    end
  end

  defp push_row(row, {:ok, count, bytes, frame}, port, width, timeout)
       when is_list(row) and length(row) == width do
    encoded = Digest.encode_row(row)
    batch = {:ok, count + 1, bytes + IO.iodata_length(encoded), [frame | encoded]}
    flush_full(batch, port, timeout)
  end

  defp push_row(_row, _acc, _port, _width, _timeout),
    do: {:halt, {:error, Error.new(:parquet_bad_row, "a row does not match the columns")}}

  defp flush_full({:ok, count, bytes, frame}, port, timeout)
       when count >= @batch_rows or bytes >= @batch_bytes do
    case flush(port, count, frame, timeout) do
      :ok -> {:cont, {:ok, 0, 0, []}}
      {:error, _} = error -> {:halt, error}
    end
  end

  defp flush_full(batch, _port, _timeout), do: {:cont, batch}

  defp flush(port, count, frame, timeout),
    do: call_ok(port, [<<@version, 2, count::32>> | frame], timeout)

  defp open_frame(path, columns) do
    names =
      Enum.map(columns, fn name when is_binary(name) and name != "" ->
        <<byte_size(name)::16, name::binary>>
      end)

    [<<@version, 1, byte_size(path)::32>>, path, <<length(columns)::16>> | names]
  end

  defp path_frame(op, path), do: [<<@version, op, byte_size(path)::32>>, path]

  defp summary(frame) do
    case split_summary(frame) do
      {:ok, summary, <<>>} -> {:ok, summary}
      {:ok, _summary, _rest} -> malformed()
      {:error, _} = error -> error
    end
  end

  defp split_summary(<<@version, 0, rows::64, digest::binary-size(32), bytes::64, rest::binary>>),
    do: {:ok, %{rows: rows, digest: digest, bytes: bytes}, rest}

  defp split_summary(_frame), do: malformed()

  defp columns(<<count::16, rest::binary>>), do: columns(rest, count, [])
  defp columns(_binary), do: malformed()

  defp columns(<<>>, 0, acc), do: {:ok, Enum.reverse(acc)}

  defp columns(<<len::16, name::binary-size(len), rest::binary>>, count, acc) when count > 0,
    do: columns(rest, count - 1, [name | acc])

  defp columns(_binary, _count, _acc), do: malformed()

  defp call_ok(port, frame, timeout) do
    case call(port, frame, timeout) do
      {:ok, <<@version, 0>>} -> :ok
      {:ok, _frame} -> malformed()
      {:error, _} = error -> error
    end
  end

  defp call(port, frame, timeout) do
    Port.command(port, frame)
    await(port, timeout)
  catch
    :error, :badarg -> unavailable("archive program is not running")
  end

  defp await(port, timeout) do
    receive do
      {^port, {:data, <<@version, 0, _::binary>> = frame}} ->
        {:ok, frame}

      {^port, {:data, <<@version, status, len::32, message::binary-size(len)>>}}
      when is_map_key(@codes, status) ->
        {:error, Error.new(Map.fetch!(@codes, status), message)}

      {^port, {:data, _frame}} ->
        malformed()

      {^port, {:exit_status, status}} ->
        unavailable("archive program exited with #{status}")
    after
      timeout -> {:error, Error.new(:parquet_timeout, "archive program timed out")}
    end
  end

  defp start(opts) do
    executable = Keyword.get_lazy(opts, :executable, &bundled_program/0)

    with :ok <- verify_program(executable, Keyword.get(opts, :sha256, @embedded_sha256)),
         {:ok, port} <- open(executable) do
      {:ok, port, Keyword.get(opts, :timeout, @default_timeout)}
    end
  end

  defp open(executable) do
    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        :use_stdio,
        :hide,
        {:packet, 4}
      ])

    Process.unlink(port)
    {:ok, port}
  rescue
    error in ErlangError ->
      unavailable("archive program cannot start: #{inspect(error.original)}")
  end

  defp close(port) do
    Port.close(port)
    flush_messages(port)
  catch
    :error, :badarg -> flush_messages(port)
  end

  defp flush_messages(port) do
    receive do
      {^port, _message} -> flush_messages(port)
    after
      0 -> :ok
    end
  end

  # T-53
  # OP-84
  defp verify_program(_executable, nil),
    do: {:error, Error.new(:parquet_integrity, "archive program has no embedded checksum")}

  # sobelow_skip ["Traversal.FileModule"]
  defp verify_program(executable, expected) do
    case File.read(executable) do
      {:ok, binary} ->
        actual = :crypto.hash(:sha256, binary) |> Base.encode16(case: :lower)

        if String.downcase(expected) == actual,
          do: :ok,
          else: {:error, Error.new(:parquet_integrity, "archive program checksum does not match")}

      {:error, _} ->
        {:error, Error.new(:parquet_integrity, "archive program is missing")}
    end
  end

  defp bundled_program, do: Application.app_dir(:relay, @program)

  defp malformed, do: unavailable("archive program sent a malformed response")
  defp unavailable(message), do: {:error, Error.new(:parquet_unavailable, message)}
end
