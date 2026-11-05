defmodule RelayWeb.Links.Unconfigured do
  @moduledoc "The link handler of an installation without one: every link is invalid and nothing is applied."

  @behaviour RelayWeb.Links

  @impl RelayWeb.Links
  def describe(_token), do: {:error, :invalid}

  @impl RelayWeb.Links
  def apply_link(_token, _evidence), do: {:error, :invalid}
end
