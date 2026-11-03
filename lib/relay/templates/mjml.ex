defmodule Relay.Templates.Mjml do
  @moduledoc """
  MJML compiler client. Every call verifies the `mjml_port` program against its SHA-256, starts it as a fresh OS process, sends one request and reads one response, so no tenant's source shares a process with another's and a crash or overrun ends only that call. The program runs under a hard deadline that it also enforces on itself, refuses `mj-include`, links only the fonts the template declares with `mj-font`, and caps input at 256 KiB and output at a configurable limit. It runs only when a template version is published, never on the send path.
  """

  alias Relay.Error

  @version 1
  @max_input 256 * 1024
  @max_output 4 * 1024 * 1024
  @default_max_output 2 * 1024 * 1024
  @default_timeout 2_000
  @program "priv/native/mjml_port"
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
    1 => :mjml_bad_request,
    2 => :mjml_bad_request,
    3 => :mjml_input_too_large,
    4 => :mjml_output_too_large,
    5 => :mjml_encoding,
    6 => :mjml_include,
    7 => :mjml_parse,
    8 => :mjml_render
  }
  @exit_deadline 5

  @type option ::
          {:executable, Path.t()}
          | {:sha256, String.t() | nil}
          | {:timeout, pos_integer()}
          | {:max_output, pos_integer()}

  # T-98
  # TP-8
  # TP-6
  # T-53
  @doc """
  Compiles an MJML document to HTML at publish time. Call it before Liquid rendering: Liquid tags (`{{ var }}`, `{% if %}`) in the source pass through compilation verbatim and are rendered later on the compiled HTML. Never call it on the send path (TP-8).

  Options: `:timeout` in milliseconds (default #{@default_timeout}); `:max_output` in bytes (default #{@default_max_output}, at most #{@max_output}); `:executable` (default the program bundled in the release) and `:sha256` (default the checksum embedded at compile time).

  Errors carry the codes `:mjml_input_too_large`, `:mjml_output_too_large`, `:mjml_encoding`, `:mjml_include`, `:mjml_parse`, `:mjml_render`, `:mjml_bad_request`, `:mjml_timeout`, `:mjml_unavailable` and `:mjml_integrity`; source errors carry one-based `:line` and `:column` in `details` when the position is known.
  """
  @spec compile(String.t(), [option()]) :: {:ok, String.t()} | {:error, Error.t()}
  def compile(mjml, opts \\ []) when is_binary(mjml) and is_list(opts) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    max_output = opts |> Keyword.get(:max_output, @default_max_output) |> min(@max_output)
    executable = Keyword.get_lazy(opts, :executable, &bundled_program/0)

    with :ok <- check_size(mjml),
         :ok <- verify(executable, Keyword.get(opts, :sha256, @embedded_sha256)) do
      run(executable, request(timeout, max_output, mjml), timeout)
    end
  end

  defp check_size(mjml) when byte_size(mjml) > @max_input do
    message = "MJML source exceeds #{@max_input} bytes"
    {:error, Error.new(:mjml_input_too_large, message, %{limit: @max_input})}
  end

  defp check_size(_mjml), do: :ok

  defp request(timeout, max_output, mjml),
    do: <<@version, timeout::32, max_output::32, byte_size(mjml)::32, mjml::binary>>

  defp run(executable, request, timeout) do
    case open(executable) do
      {:ok, port} ->
        try do
          send_request(port, request)
          await(port, timeout)
        after
          close(port)
        end

      {:error, _} = error ->
        error
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
      unavailable("MJML compiler cannot start: #{inspect(error.original)}")
  end

  defp send_request(port, request) do
    Port.command(port, request)
  catch
    :error, :badarg -> false
  end

  defp await(port, timeout) do
    receive do
      {^port, {:data, frame}} -> decode(frame)
      {^port, {:exit_status, @exit_deadline}} -> timed_out()
      {^port, {:exit_status, status}} -> unavailable("MJML compiler exited with #{status}")
    after
      timeout -> timed_out()
    end
  end

  defp decode(<<@version, 0, len::32, html::binary-size(len)>>), do: {:ok, html}

  defp decode(<<@version, status, line::32, column::32, len::32, message::binary-size(len)>>)
       when is_map_key(@codes, status),
       do: {:error, Error.new(Map.fetch!(@codes, status), message, position(line, column))}

  defp decode(_frame), do: unavailable("MJML compiler sent a malformed response")

  defp position(line, column) when line > 0 and column > 0, do: %{line: line, column: column}
  defp position(_line, _column), do: %{}

  defp close(port) do
    Port.close(port)
    flush(port)
  catch
    :error, :badarg -> flush(port)
  end

  defp flush(port) do
    receive do
      {^port, _message} -> flush(port)
    after
      0 -> :ok
    end
  end

  # T-53
  # T-98
  defp verify(_executable, nil),
    do: {:error, Error.new(:mjml_integrity, "MJML compiler has no embedded checksum")}

  # sobelow_skip ["Traversal.FileModule"]
  defp verify(executable, expected) do
    case File.read(executable) do
      {:ok, binary} ->
        actual = :crypto.hash(:sha256, binary) |> Base.encode16(case: :lower)

        if String.downcase(expected) == actual,
          do: :ok,
          else: {:error, Error.new(:mjml_integrity, "MJML compiler checksum does not match")}

      {:error, _} ->
        {:error, Error.new(:mjml_integrity, "MJML compiler is missing")}
    end
  end

  defp bundled_program, do: Application.app_dir(:relay, @program)

  defp timed_out, do: {:error, Error.new(:mjml_timeout, "MJML compilation timed out")}
  defp unavailable(message), do: {:error, Error.new(:mjml_unavailable, message)}
end
