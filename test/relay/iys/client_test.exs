defmodule Relay.Iys.ClientTest do
  use ExUnit.Case, async: false

  alias Relay.Iys.Client
  alias Relay.Iys.TokenCache
  alias Relay.Redacted
  alias RelayTest.IysFake, as: Fake

  @brand 9001

  setup do
    start_supervised!({Fake, []})
    cache = start_supervised!({TokenCache, name: nil})

    conn = %{
      base_url: "http://iys.invalid",
      iys_code: 600_001,
      integrator_code: 700_001,
      username: "iys-user",
      password: Redacted.wrap("iys-password"),
      cache_key: {:client_test, System.unique_integer()},
      cache: cache
    }

    %{conn: conn, cache: cache}
  end

  defp consent(changes \\ %{}) do
    Map.merge(
      %{
        recipient: "+905321112233",
        type: "MESAJ",
        status: "ONAY",
        recipient_type: "BIREYSEL",
        source: "HS_WEB",
        consent_at: DateTime.add(DateTime.utc_now(), -60, :second)
      },
      changes
    )
  end

  defp count(operation) do
    Enum.count(Fake.calls(), fn {name, _status} -> name == operation end)
  end

  describe "PC-34 the access token" do
    test "PC-34: the token is requested once and served from the cache for its lifetime", ctx do
      assert {:ok, first} = Client.token(ctx.conn)
      assert {:ok, [%{brand_code: @brand}]} = Client.brands(ctx.conn)
      assert {:ok, _subscription} = Client.subscription(ctx.conn)
      assert {:ok, second} = Client.token(ctx.conn)

      assert Redacted.expose(first) == Redacted.expose(second)
      assert count(:token) == 1
      refute inspect(first) =~ Redacted.expose(first)
    end

    test "PC-34: a limited token endpoint blocks the key and is not asked again", ctx do
      :ok = Fake.put(:token_limit, 0)

      assert {:error, %{class: :rate_limited, status: 429, code: "H084", retry_after_s: 3600}} =
               Client.token(ctx.conn)

      assert {:error, %{class: :rate_limited, code: "H084", retry_after_s: left}} =
               Client.brands(ctx.conn)

      assert left > 3590
      assert count(:token) == 1
      assert count(:brands) == 0
    end

    test "PC-34: wrong credentials are unauthorised and nothing is cached", ctx do
      conn = %{ctx.conn | password: Redacted.wrap("wrong")}

      assert {:error, %{class: :unauthorised, status: 401, code: "H251"}} = Client.token(conn)
      assert TokenCache.lookup(ctx.cache, conn.cache_key) == :miss
    end

    test "PC-34: a token İYS no longer accepts is replaced once", ctx do
      assert {:ok, _token} = Client.token(ctx.conn)
      :ok = Fake.put(:access, %{})

      assert {:ok, [%{brand_code: @brand}]} = Client.brands(ctx.conn)
      assert Fake.calls() == [token: 200, brands: 401, token: 200, brands: 200]
    end

    test "PC-34: the limiter of the connection is asked before a request leaves", ctx do
      conn = Map.put(ctx.conn, :rate, fn _kind -> {:deny, 1500} end)

      assert {:error, %{class: :rate_limited, retry_after_s: 2}} = Client.brands(conn)
      assert Fake.calls() == []
    end
  end

  describe "PC-30 single consents" do
    test "PC-30: the v2 add answers the same transaction for a repeated request", ctx do
      movement = consent()

      assert {:ok, first} = Client.add_consent(ctx.conn, @brand, movement)
      assert {:ok, again} = Client.add_consent(ctx.conn, @brand, movement)

      assert first.transaction_id =~ ~r/\A[0-9a-f]{64}\z/
      assert again.transaction_id == first.transaction_id
      assert %DateTime{} = first.registered_at
      assert first.trace =~ ~r/\A[0-9a-f]{32}\z/
      assert map_size(Fake.consents()) == 1
    end

    test "PC-30: the status of a recorded consent is read back and an unknown one is nil", ctx do
      assert {:ok, added} = Client.add_consent(ctx.conn, @brand, consent())
      query = %{recipient: "+905321112233", type: "MESAJ", recipient_type: "BIREYSEL"}

      assert {:ok, %{status: "ONAY", transaction_id: id, source: "HS_WEB"}} =
               Client.consent_status(ctx.conn, @brand, query)

      assert id == added.transaction_id
      assert {:ok, nil} = Client.consent_status(ctx.conn, @brand, %{query | type: "ARAMA"})
    end

    test "PC-34: İYS refusals, limits and outages are told apart", ctx do
      refusal = consent(%{status: "RET"})

      assert {:error, %{class: :rejected, status: 400, code: "H175", trace: trace}} =
               Client.add_consent(ctx.conn, @brand, refusal)

      assert trace =~ ~r/\A[0-9a-f]{32}\z/

      for {status, code, class, wait} <- [
            {503, "H192", :retry, nil},
            {400, "H123", :retry, nil},
            {429, "H124", :rate_limited, 1},
            {403, "H353", :forbidden, nil},
            {422, "H467", :rejected, nil}
          ] do
        :ok = Fake.fail_next(:add, status, code)

        assert {:error, %{class: ^class, status: ^status, code: ^code, retry_after_s: ^wait}} =
                 Client.add_consent(ctx.conn, @brand, consent())
      end

      :ok = Fake.fail_next(:status, 429, "H086")
      query = %{recipient: "+905321112233", type: "MESAJ"}

      assert {:error, %{class: :rate_limited, retry_after_s: 3600}} =
               Client.consent_status(ctx.conn, @brand, query)
    end
  end

  describe "PC-34 batches" do
    test "PC-34: a batch is accepted with a request id and read after 300 seconds", ctx do
      list = [
        consent(),
        consent(%{recipient: "ayse@example.com", type: "EPOSTA"}),
        consent(%{recipient: "+905321112244", status: "RET"})
      ]

      assert {:ok, %{request_id: request_id}} = Client.add_batch(ctx.conn, @brand, list)
      assert {:ok, []} = Client.batch_status(ctx.conn, @brand, request_id)

      :ok = Fake.advance(301)

      assert {:ok, [first, second, third]} = Client.batch_status(ctx.conn, @brand, request_id)
      assert %{index: 0, status: "success", transaction_id: <<_::binary-64>>} = first
      assert %{index: 1, status: "success", error_code: nil} = second
      assert %{index: 2, status: "failure", error_code: "H175", transaction_id: nil} = third
    end
  end

  describe "PC-32 changes" do
    test "PC-32: movements are read oldest first with the cursor of the last answer", ctx do
      movement = %{"recipient" => "+905321110001", "type" => "MESAJ", "status" => "ONAY"}
      :ok = Fake.citizen(@brand, movement)
      :ok = Fake.advance(2)
      :ok = Fake.citizen(@brand, %{movement | "status" => "RET"})

      assert {:ok, %{list: [], after: nil}} = Client.changes(ctx.conn, @brand, source: "IYS")

      :ok = Fake.advance(3700)

      assert {:ok, %{list: [%{"status" => "ONAY"}], after: cursor}} =
               Client.changes(ctx.conn, @brand, source: "IYS", limit: 1)

      assert {:ok, %{list: [%{"status" => "RET", "source" => "IYS_WEB"}], after: last}} =
               Client.changes(ctx.conn, @brand, source: "IYS", after: cursor)

      assert {:ok, %{list: [], after: ^last}} =
               Client.changes(ctx.conn, @brand, source: "IYS", after: last)

      assert {:ok, %{list: []}} = Client.changes(ctx.conn, @brand, source: "HS")
    end
  end

  describe "PC-29 PC-34 the connection" do
    test "PC-29: the integrator's authorisations are read page by page, never assumed", ctx do
      access = %{"MESAJ" => "write", "ARAMA" => "read", "EPOSTA" => "yok"}
      :ok = Fake.put(:authorisations, Map.new(1..150, &{&1, access}))

      assert {:ok, list} = Client.authorisations(ctx.conn)
      assert length(list) == 150

      assert %{brand_code: 1, message_access: "write", call_access: "read"} = hd(list)
      assert hd(list).email_access == "none"

      assert count(:authorisations) == 2
    end

    test "PC-34: the subscription carries the consent quota", ctx do
      assert {:ok, subscription} = Client.subscription(ctx.conn)

      assert %{status: "ACTIVE", consent_limit: 1000, used_consent_limit: 0} = subscription
      assert subscription.consent_limit_exceed == false
    end
  end

  describe "PC-56 the fake" do
    test "PC-56: the fake limits requests to ten a second as İYS does", ctx do
      :ok = Fake.freeze()
      :ok = Fake.put(:enforce_rates, true)
      assert {:ok, _token} = Client.token(ctx.conn)

      for _call <- 1..10, do: assert({:ok, _brands} = Client.brands(ctx.conn))

      assert {:error, %{class: :rate_limited, code: "H124", retry_after_s: 1}} =
               Client.brands(ctx.conn)

      :ok = Fake.advance(1)
      assert {:ok, _brands} = Client.brands(ctx.conn)
    end

    test "PC-56: the fake refuses what the document says İYS refuses", ctx do
      old = consent(%{consent_at: DateTime.add(DateTime.utc_now(), -10 * 86_400, :second)})
      assert {:error, %{code: "H467"}} = Client.add_consent(ctx.conn, @brand, old)

      assert {:ok, _added} = Client.add_consent(ctx.conn, @brand, consent())
      later = consent(%{consent_at: DateTime.add(DateTime.utc_now(), -30, :second)})
      assert {:error, %{code: "H174", status: 400}} = Client.add_consent(ctx.conn, @brand, later)

      :ok = Fake.put(:subscription, Map.put(Fake.get(:subscription), "consentLimit", 1))
      other = consent(%{recipient: "+905321112299"})
      assert {:error, %{code: "H525", status: 422}} = Client.add_consent(ctx.conn, @brand, other)
    end
  end
end
