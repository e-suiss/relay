defmodule Relay.Templates.MjmlTest do
  use ExUnit.Case, async: false

  alias Relay.Templates.Mjml

  @moduletag :tmp_dir

  defp fake(dir, body) do
    exe = Path.join(dir, "mjml_port")
    File.write!(exe, "#!/bin/sh\n" <> body <> "\n")
    File.chmod!(exe, 0o755)
    exe
  end

  defp checksum(path), do: :crypto.hash(:sha256, File.read!(path)) |> Base.encode16(case: :lower)

  defp compile(exe, opts) do
    opts = Keyword.put_new_lazy(opts, :sha256, fn -> checksum(exe) end)
    Mjml.compile("<mjml><mj-body /></mjml>", Keyword.put(opts, :executable, exe))
  end

  test "T-98: the compiled HTML travels back over the port", %{tmp_dir: dir} do
    exe = fake(dir, ~S"printf '\000\000\000\010\001\000\000\000\000\002hi'")
    assert compile(exe, timeout: 30_000) == {:ok, "hi"}
  end

  test "T-98: a source error comes back with its position", %{tmp_dir: dir} do
    exe =
      fake(
        dir,
        ~S"printf '\000\000\000\017\001\007\000\000\000\003\000\000\000\005\000\000\000\001x'"
      )

    assert {:error, %Relay.Error{code: :mjml_parse, message: "x", details: details}} =
             compile(exe, timeout: 30_000)

    assert details == %{line: 3, column: 5}
  end

  test "T-98: an overrun is cut off at the timeout", %{tmp_dir: dir} do
    exe = fake(dir, "exec sleep 5")
    assert {:error, %Relay.Error{code: :mjml_timeout}} = compile(exe, timeout: 100)
    refute_received {_, {:data, _}}
    refute_received {_, {:exit_status, _}}
  end

  test "T-98: the program's own deadline exit is a timeout", %{tmp_dir: dir} do
    exe = fake(dir, "exit 5")
    assert {:error, %Relay.Error{code: :mjml_timeout}} = compile(exe, timeout: 30_000)
  end

  test "T-98: a crash or a malformed response leaves the caller standing", %{tmp_dir: dir} do
    crash = fake(dir, "exit 3")
    assert {:error, %Relay.Error{code: :mjml_unavailable}} = compile(crash, timeout: 30_000)

    File.rm!(crash)
    garbage = fake(dir, ~S"printf '\000\000\000\002\011\011'")
    assert {:error, %Relay.Error{code: :mjml_unavailable}} = compile(garbage, timeout: 30_000)
  end

  test "T-53: the program is refused when its checksum does not match", %{tmp_dir: dir} do
    exe = fake(dir, "exit 0")

    assert {:error, %Relay.Error{code: :mjml_integrity}} =
             compile(exe, sha256: String.duplicate("0", 64))

    assert {:error, %Relay.Error{code: :mjml_integrity}} = compile(exe, sha256: nil)

    assert {:error, %Relay.Error{code: :mjml_integrity}} =
             compile(Path.join(dir, "missing"), sha256: String.duplicate("0", 64))
  end

  test "TP-6: a source above 256 KiB is refused before the program starts", %{tmp_dir: dir} do
    exe = fake(dir, "exit 3")
    source = String.duplicate("a", 256 * 1024 + 1)

    assert {:error, %Relay.Error{code: :mjml_input_too_large}} =
             Mjml.compile(source, executable: exe, sha256: checksum(exe))
  end

  test "TP-8: the compiler is documented and enforced as publish-time only" do
    {:docs_v1, _, _, _, _, _, docs} = Code.fetch_docs(Mjml)

    assert [doc] =
             for({{:function, :compile, 2}, _, _, %{"en" => doc}, _} <- docs, do: doc)

    assert doc =~ "Never call it on the send path (TP-8)"
    assert doc =~ "before Liquid rendering"
    assert File.read!(".credo.exs") =~ "RelayDev.Credo.MjmlOnSendPath"
  end
end
