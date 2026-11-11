defmodule Relay.Channels.Email.TrackingTest do
  use ExUnit.Case, async: true

  alias Relay.Channels.Email.Tracking

  @tenant <<1::128>>
  @delivery <<2::128>>
  @root "https://relay.example"

  defp scope, do: Relay.Scope.new!(@tenant, :live)
  defp mac, do: fn message -> {:ok, :crypto.mac(:hmac, :sha256, "tracking-key", message)} end
  defp other_mac, do: fn message -> {:ok, :crypto.mac(:hmac, :sha256, "other-key", message)} end
  defp both, do: %{open_pixel: true, wrap_links: true}

  describe "CH-43 CH-44 DS-29 tracking plan" do
    test "CH-43: tracking is off unless the tenant turns it on" do
      assert Tracking.plan(%{class: "transactional"}) == %{open_pixel: false, wrap_links: false}

      assert Tracking.plan(%{class: "marketing", open_pixel: true, wrap_links: true}) == both()
    end

    test "CH-44: a security e-mail or a verification subtype is never tracked" do
      for message <- [
            %{class: "security", open_pixel: true, wrap_links: true},
            %{class: "transactional", security_subtype: "email_verification", wrap_links: true}
          ] do
        assert Tracking.plan(message) == %{open_pixel: false, wrap_links: false}
      end
    end

    test "DS-29: a template's setting replaces its category's" do
      settings = %{
        "email.tracking.category.news" => %{"open_pixel" => true, "wrap_links" => true},
        "email.tracking.template.t_weekly_news" => %{"open_pixel" => false, "wrap_links" => true}
      }

      assert Tracking.configured(settings, "news", "weekly-news") ==
               %{open_pixel: false, wrap_links: true}

      assert Tracking.configured(settings, "news", "other") == both()
      assert Tracking.configured(%{}, "news", nil) == %{open_pixel: false, wrap_links: false}
    end
  end

  describe "CH-43 tracking tokens and the HTML part" do
    test "CH-43: links are wrapped with signed tokens and the pixel is appended" do
      html =
        ~s(<html><body><a href="https://shop.example/a?x=1&amp;y=2">A</a> ) <>
          ~s(<a href='mailto:help@example.com'>M</a><a class="b" href="http://b.example">B</a>) <>
          "</body></html>"

      assert {:ok, out} = Tracking.instrument(html, both(), {scope(), @delivery}, {@root, mac()})
      refute out =~ "shop.example"
      assert out =~ "mailto:help@example.com"

      tokens = Regex.scan(~r{https://relay\.example/e/c/([A-Za-z0-9_-]+)}, out)
      assert [[_, first], [_, second]] = tokens
      assert out =~ ~r{<img src="https://relay\.example/e/o/[A-Za-z0-9_-]+"[^>]*></body>}

      assert {:ok, %{kind: :click, link: 1, url: "https://shop.example/a?x=1&y=2"} = decoded} =
               Tracking.read(first, :click, fn _scope -> mac() end)

      assert decoded.scope == scope()
      assert decoded.delivery_id == @delivery

      assert {:ok, %{link: 2, url: "http://b.example"}} =
               Tracking.read(second, :click, fn _scope -> mac() end)
    end

    test "CH-44: a token that does not verify, or of the other kind, is invalid" do
      {:ok, token} = Tracking.token(scope(), @delivery, {:click, 1, "https://a.example"}, mac())

      assert {:error, :invalid} = Tracking.read(token, :click, fn _scope -> other_mac() end)
      assert {:error, :invalid} = Tracking.read(token, :open, fn _scope -> mac() end)
      assert {:error, :invalid} = Tracking.read("not-a-token", :click, fn _scope -> mac() end)

      {:ok, open} = Tracking.token(scope(), @delivery, :open, mac())
      assert {:ok, %{kind: :open, url: nil}} = Tracking.read(open, :open, fn _scope -> mac() end)
    end

    test "CH-43: an e-mail without HTML or with nothing on is unchanged" do
      off = %{open_pixel: false, wrap_links: false}
      html = ~s(<a href="https://a.example">A</a>)

      assert Tracking.instrument(nil, both(), {scope(), @delivery}, {@root, mac()}) == {:ok, nil}
      assert Tracking.instrument(html, off, {scope(), @delivery}, {@root, mac()}) == {:ok, html}
    end
  end
end
