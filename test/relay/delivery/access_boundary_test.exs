defmodule Relay.Delivery.AccessBoundaryTest do
  use Relay.SqlCase, async: false

  @sources [
    "lib/relay/delivery.ex",
    "lib/relay/delivery_windows.ex",
    "lib/relay/delivery/**/*.ex"
  ]

  @functions ~w(ledger_append ledger_record projection_reduce projection_apply
                delivery_windows_advance delivery_status delivery_projection_rebuild)

  describe "E-6 DS-43 INV-28 delivery is information, never authority" do
    test "E-6, E-7, DS-43: the delivery context never calls Access" do
      files = Enum.flat_map(@sources, &Path.wildcard/1)
      assert files != []

      for path <- files do
        refute File.read!(path) =~ ~r/Relay\.(Access|Operators\.Access)\b/, path
      end
    end

    test "INV-28, DS-43: the ledger and projection functions touch no Access state" do
      found =
        rows(
          "SELECT p.proname, p.prosrc FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname IN ('relay_fn', 'relay_private') AND p.proname = ANY ($1)",
          [@functions]
        )

      assert length(found) >= length(@functions)

      for [name, source] <- found do
        refute source =~ ~r/relay\.(access_|api_clients|operators)/, name
      end
    end
  end
end
