defmodule EsuissRelay.PageTest do
  use ExUnit.Case, async: true

  alias EsuissRelay.Api
  alias EsuissRelay.Page
  alias EsuissRelay.Stub

  defp list(ids, next) do
    Stub.json(200, %{
      "object" => "list",
      "data" => Enum.map(ids, &%{"id" => &1}),
      "has_more" => next != nil,
      "next_cursor" => next
    })
  end

  test "API-56: the page iterator reads the next page only when it needs it" do
    second = list(["wp_3"], "c2")

    {client, stub} =
      Stub.client([list(["wp_1", "wp_2"], "c1"), second, second, list(["wp_4"], nil)])

    assert {:ok, %Page{has_more: true, next_cursor: "c1"} = page} =
             Api.list_waitpoints(client, state: "open", limit: 2)

    assert ["wp_1", "wp_2"] = Enum.map(Enum.take(page, 2), & &1["id"])
    assert length(Stub.requests(stub)) == 1

    assert ["wp_1", "wp_2", "wp_3"] = Enum.map(Enum.take(page, 3), & &1["id"])
    assert length(Stub.requests(stub)) == 2

    assert ["wp_1", "wp_2", "wp_3", "wp_4"] = page |> Page.stream() |> Enum.map(& &1["id"])

    urls = stub |> Stub.requests() |> Enum.map(& &1.url)

    assert urls == [
             "https://relay.test/v1/waitpoints?limit=2&state=open",
             "https://relay.test/v1/waitpoints?limit=2&starting_after=c1&state=open",
             "https://relay.test/v1/waitpoints?limit=2&starting_after=c1&state=open",
             "https://relay.test/v1/waitpoints?limit=2&starting_after=c2&state=open"
           ]
  end

  test "API-56: a last page has no next page and a failed next page raises its error" do
    {client, _stub} = Stub.client([list(["wp_1"], nil)])
    assert {:ok, page} = Api.list_waitpoints(client)
    assert {:ok, nil} = Page.next(page)
    assert Enum.to_list(page) == [%{"id" => "wp_1"}]

    not_found = Stub.json(404, %{"code" => "resource_not_found", "retryable" => false})
    {client, _stub} = Stub.client([list(["wp_1"], "c1"), not_found])
    assert {:ok, page} = Api.list_waitpoints(client)
    assert_raise EsuissRelay.NotFoundError, fn -> Enum.to_list(page) end
  end
end
