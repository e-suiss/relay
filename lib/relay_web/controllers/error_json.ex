defmodule RelayWeb.ErrorJSON do
  @moduledoc false

  @spec render(String.t(), map()) :: map()
  def render(template, _assigns) do
    status = template |> String.split(".") |> hd() |> String.to_integer()

    %{
      type: "about:blank",
      title: Phoenix.Controller.status_message_from_template(template),
      status: status
    }
  end
end
