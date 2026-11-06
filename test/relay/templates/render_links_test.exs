defmodule Relay.Templates.RenderLinksTest do
  use ExUnit.Case, async: true

  @href "https://example.com/orders/1"

  defp render(channel, cell, links) do
    Relay.Templates.render_cell(%{
      channel: channel,
      cell: cell,
      locale: "en",
      time_zone: "Etc/UTC",
      data: %{},
      links: links,
      sensitivity: :public
    })
  end

  describe "E-83 links" do
    test "E-83: a template reads a link as links.<rel> and the primary link is the push target" do
      cell = %{"title" => "Order", "body" => "Open {{ links.primary }}"}

      assert {:ok, %{output: output}} = render(:push, cell, %{"primary" => @href})
      assert output["url"] == @href
      assert output["body"] == "Open " <> @href
    end

    test "E-83: without a primary link the push output has no target" do
      cell = %{"title" => "Order", "body" => "Shipped"}

      assert {:ok, %{output: output}} = render(:push, cell, %{"other" => @href})
      refute Map.has_key?(output, "url")

      assert {:ok, %{output: plain}} = render(:push, cell, %{})
      refute Map.has_key?(plain, "url")
    end

    test "E-83: the primary link is the inbox item's target" do
      cell = %{"title" => "Order", "body" => "Shipped"}

      assert {:ok, %{output: output}} = render(:in_app, cell, %{"primary" => @href})
      assert output["url"] == @href
    end
  end
end
