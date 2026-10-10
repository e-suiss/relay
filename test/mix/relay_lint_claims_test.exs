defmodule RelayDev.Lint.ClaimsTest do
  use ExUnit.Case, async: true

  import RelayDev.Fixture

  alias RelayDev.Lint.Claims

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    File.mkdir_p!(Path.join(dir, "conformance/catalog"))
    File.cp!("conformance/catalog/claims.json", Path.join(dir, "conformance/catalog/claims.json"))
    :ok
  end

  describe "F-31 INV-60 claim language" do
    test "F-31: forbidden claims are rejected in READMEs and documentation strings", %{
      tmp_dir: dir
    } do
      write!(dir, %{
        "README.md" =>
          "Relay offers exactly-once delivery.\nThe push was delivered.\nUsing Relay guarantees compliance.\n",
        "lib/relay/a.ex" =>
          ~s(@moduledoc "Idempotency-Key is an IETF standard. Data is permanently deleted."\n)
      })

      ids = dir |> Claims.run() |> rules()
      assert length(ids) == 5
      assert "exactly_once_delivery (F-25)" in ids
    end

    test "INV-60: the allowed wording passes and a marked quotation is allowed", %{tmp_dir: dir} do
      write!(dir, %{
        "README.md" => """
        At-least-once delivery with durable idempotency gives effectively-once processing.
        The provider accepted the push.
        We never say "exactly-once delivery". <!-- claims-allow -->
        """
      })

      assert Claims.run(dir) == []
    end
  end
end
