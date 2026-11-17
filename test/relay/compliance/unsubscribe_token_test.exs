defmodule Relay.Compliance.UnsubscribeTokenTest do
  use ExUnit.Case, async: false

  alias Relay.Compliance
  alias Relay.Compliance.Refusal

  defp claims(overrides \\ %{}) do
    Map.merge(
      %{
        scope: Relay.Scope.new!(Relay.Id.generate(), :live),
        id: Relay.Id.generate(),
        recipient_id: Relay.Id.generate(),
        category: "news",
        channel: "email",
        brand_subtenant_id: nil
      },
      overrides
    )
  end

  defp parts(token) do
    [fields, signature] = String.split(token, ".")
    {Base.url_decode64!(fields, padding: false), Base.url_decode64!(signature, padding: false)}
  end

  defp token(fields, signature), do: part(fields) <> "." <> part(signature)

  defp part(binary), do: Base.url_encode64(binary, padding: false)

  defp configure(changes) do
    previous = Application.get_env(:relay, Relay.Compliance, [])
    Application.put_env(:relay, Relay.Compliance, Keyword.merge(previous, changes))
    on_exit(fn -> Application.put_env(:relay, Relay.Compliance, previous) end)
  end

  describe "PC-35 TN-35 the unsubscribe token" do
    test "PC-35: a token carries tenant, recipient, category, channel and brand and verifies" do
      brand = Relay.Id.generate()
      claims = claims(%{brand_subtenant_id: brand})

      assert {:ok, token} = Compliance.issue_unsubscribe_token(claims)
      assert {:ok, ^claims} = Compliance.verify_unsubscribe_token(token)
      assert {:ok, plain} = Compliance.issue_unsubscribe_token(claims(%{scope: claims.scope}))
      assert {:ok, %{brand_subtenant_id: nil}} = Compliance.verify_unsubscribe_token(plain)
    end

    test "TN-35: the token states its purpose and scope and is signed with ES256" do
      {:ok, token} = Compliance.issue_unsubscribe_token(claims())
      {fields, signature} = parts(token)

      assert <<1, 1, 1, 0, _rest::binary>> = fields
      assert byte_size(signature) == 64
      refute token =~ "="

      <<version, _purpose, scope, rest::binary>> = fields
      other = token(<<version, 2, scope, rest::binary>>, signature)
      assert {:error, :invalid} = Compliance.verify_unsubscribe_token(other)
    end

    test "PC-35: a token has no expiry: its fields hold no time" do
      {:ok, token} = Compliance.issue_unsubscribe_token(claims())
      {fields, _signature} = parts(token)
      label = "unsubscribe-link"

      assert byte_size(fields) ==
               4 + 3 * 16 + 1 + 1 + byte_size("email") + 1 + byte_size("news") + 1 +
                 byte_size(label)
    end

    test "PC-35: a tampered token, a foreign signature and anything else are invalid" do
      claims = claims()
      {:ok, token} = Compliance.issue_unsubscribe_token(claims)
      {fields, signature} = parts(token)

      changed = binary_part(fields, 0, byte_size(fields) - 1) <> "x"
      assert {:error, :invalid} = Compliance.verify_unsubscribe_token(token(changed, signature))

      {:ok, other} = Compliance.issue_unsubscribe_token(claims(%{category: "deals"}))
      {_other_fields, other_signature} = parts(other)
      forged = token(fields, other_signature)
      assert {:error, :invalid} = Compliance.verify_unsubscribe_token(forged)

      for junk <- ["", "a.b", "a", token <> ".x", nil, 42, String.duplicate("a", 2_000)] do
        assert {:error, :invalid} = Compliance.verify_unsubscribe_token(junk)
      end
    end

    test "PC-35: a token verifies under an earlier key that is still listed and under no other" do
      configure(unsubscribe_key: "unsubscribe-link-1")
      {:ok, old} = Compliance.issue_unsubscribe_token(claims())

      configure(unsubscribe_key: "unsubscribe-link-2", unsubscribe_verify_keys: [])
      assert {:error, :invalid} = Compliance.verify_unsubscribe_token(old)

      configure(unsubscribe_verify_keys: ["unsubscribe-link-1"])
      assert {:ok, _claims} = Compliance.verify_unsubscribe_token(old)
    end
  end

  describe "PC-38 PC-39 refusal scopes" do
    test "PC-39: every source has its default scope" do
      defaults = %{
        "rfc8058" => "category",
        "unsubscribe_link" => "category",
        "mailto" => "category",
        "unsubscribe_page" => "all_marketing",
        "sms_keyword" => "all_channel",
        "complaint" => "all_marketing",
        "whatsapp" => "all_marketing",
        "iys" => "all_marketing"
      }

      assert Enum.sort(Refusal.sources()) == Enum.sort(Map.keys(defaults))
      for {source, scope} <- defaults, do: assert(Compliance.default_scope(source) == scope)
      assert Compliance.default_scope("other") == nil
      assert Refusal.scopes() == ~w(category all_marketing all_channel)
    end

    test "PC-39: the scope is data and a given scope replaces the default" do
      base = %{recipient_id: Relay.Id.generate(), channel: "sms", ref: "r"}
      attrs = Map.put(base, :source, "sms_keyword")

      narrowed = Map.put(attrs, :scope, "all_marketing")
      unknown = Map.put(attrs, :scope, "everything")

      assert {:ok, %Refusal{scope: "all_channel"}} = Refusal.new(attrs)
      assert {:ok, %Refusal{scope: "all_marketing"}} = Refusal.new(narrowed)
      assert {:error, %Relay.Error{code: :validation_failed}} = Refusal.new(unknown)
    end

    test "PC-38: an exit of one message is a category preference and never a refusal notice" do
      attrs = %{recipient_id: Relay.Id.generate(), channel: "email", source: "rfc8058", ref: "r"}

      assert {:ok, left} = Refusal.new(Map.put(attrs, :category, "news"))
      refute Refusal.notice?(left)
      refute Refusal.forwarded?(left)
      assert {:error, _error} = Refusal.new(Map.put(attrs, :scope, "all_marketing"))
      assert {:error, _error} = Refusal.new(attrs)

      page = %{attrs | source: "unsubscribe_page"}
      assert {:ok, notice} = Refusal.new(page)
      assert Refusal.notice?(notice)
      assert Refusal.forwarded?(notice)
      assert {:error, _error} = Refusal.new(Map.put(page, :category, "news"))

      assert {:ok, registry} = Refusal.new(%{attrs | source: "iys"})
      assert Refusal.notice?(registry)
      refute Refusal.forwarded?(registry)
    end

    test "PC-35: personal evidence enters only redacted" do
      base = %{recipient_id: Relay.Id.generate(), channel: "email", ref: "r"}
      attrs = Map.put(base, :source, "complaint")
      ip = Relay.Redacted.wrap("203.0.113.9")

      assert {:ok, refusal} = Refusal.new(Map.put(attrs, :evidence, %{ip: ip}))
      refute inspect(refusal) =~ "203.0.113.9"
      assert {:error, _error} = Refusal.new(Map.put(attrs, :evidence, %{ip: "203.0.113.9"}))
      assert {:error, _error} = Refusal.new(Map.put(attrs, :address, "ayse@example.com"))
    end
  end
end
