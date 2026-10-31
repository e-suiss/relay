defmodule Relay.Api.CursorTest do
  use ExUnit.Case, async: true

  alias Relay.Api.Cursor
  alias Relay.Api.Pagination

  @endpoint "GET /v1/notifications"

  setup do
    tenant = Relay.Id.generate()
    position = %{sort_ts_us: 1_761_955_200_000_000, id: Relay.Id.generate()}

    %{
      live: Relay.Scope.new!(tenant, :live),
      test: Relay.Scope.new!(tenant, :test),
      other: Relay.Scope.new!(Relay.Id.generate(), :live),
      position: position
    }
  end

  defp cursor(scope, position, subject \\ nil, endpoint \\ @endpoint) do
    {:ok, cursor} = Cursor.encode(scope, subject, endpoint, position, :after)
    cursor
  end

  describe "API-56 signed cursors" do
    test "API-56: a cursor reads back in its own tenant, environment and endpoint", ctx do
      cursor = cursor(ctx.live, ctx.position)
      assert byte_size(cursor) <= 512

      assert {:ok, %{sort_ts_us: ts, id: id, direction: :after}} =
               Cursor.decode(ctx.live, nil, @endpoint, cursor, "starting_after")

      assert {ts, id} == {ctx.position.sort_ts_us, ctx.position.id}
    end

    test "API-76: the other environment's cursor is auth_environment_mismatch", ctx do
      cursor = cursor(ctx.test, ctx.position)

      assert {:error, %Relay.Error{code: :auth_environment_mismatch}} =
               Cursor.decode(ctx.live, nil, @endpoint, cursor, "starting_after")
    end

    test "API-56: another tenant's cursor is invalid and leaks nothing", ctx do
      cursor = cursor(ctx.other, ctx.position)

      assert {:error, %Relay.Error{code: :validation_failed, details: %{errors: [error]}}} =
               Cursor.decode(ctx.live, nil, @endpoint, cursor, "starting_after")

      assert error.pointer == "/starting_after"
      assert error.code == "invalid_format"
    end

    test "API-56: a cursor of another endpoint, another subscriber or a changed byte is invalid",
         ctx do
      other_endpoint = cursor(ctx.live, ctx.position, nil, "GET /v1/subscribers")
      subscriber = cursor(ctx.live, ctx.position, Relay.Id.generate())
      <<first, rest::binary>> = Base.url_decode64!(cursor(ctx.live, ctx.position), padding: false)
      tampered = Base.url_encode64(<<Bitwise.bxor(first, 1), rest::binary>>, padding: false)

      for cursor <- [other_endpoint, subscriber, tampered, "not a cursor", "AAAA"] do
        assert {:error, %Relay.Error{code: :validation_failed}} =
                 Cursor.decode(ctx.live, nil, @endpoint, cursor, "ending_before")
      end
    end
  end

  describe "API-56 pagination parameters" do
    test "API-56: limit defaults to 50 and stays within 1 to 100", ctx do
      assert {:ok, %{limit: 50, cursor: nil}} = Pagination.params(%{}, ctx.live, nil, @endpoint)
      query = %{"limit" => "100"}
      assert {:ok, %{limit: 100}} = Pagination.params(query, ctx.live, nil, @endpoint)

      for {value, code} <- [{"0", "too_short"}, {"101", "too_long"}, {"ten", "invalid_format"}] do
        assert {:error, %Relay.Error{code: :validation_failed, details: %{errors: [error]}}} =
                 Pagination.params(%{"limit" => value}, ctx.live, nil, @endpoint)

        assert {error.pointer, error.code} == {"/limit", code}
      end
    end

    test "API-56: one cursor at a time, and every invalid parameter is reported", ctx do
      cursor = cursor(ctx.live, ctx.position)
      query = %{"starting_after" => cursor, "ending_before" => cursor, "limit" => "0"}

      assert {:error, %Relay.Error{code: :validation_failed, details: %{errors: errors}}} =
               Pagination.params(query, ctx.live, nil, @endpoint)

      assert errors |> Enum.map(& &1.pointer) |> Enum.sort() == ["/ending_before", "/limit"]
    end

    test "API-56: the list envelope", ctx do
      assert {:ok, %{cursor: %{direction: :after}}} =
               Pagination.params(
                 %{"starting_after" => cursor(ctx.live, ctx.position)},
                 ctx.live,
                 nil,
                 @endpoint
               )

      assert Pagination.envelope([1], true, "c") == %{
               "object" => "list",
               "data" => [1],
               "has_more" => true,
               "next_cursor" => "c",
               "previous_cursor" => nil
             }
    end
  end
end
