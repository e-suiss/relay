defmodule Relay.Templates do
  @moduledoc """
  Templates, localisation and rendering. Other contexts use only the functions of this module.
  """

  use Boundary, top_level?: true, deps: [Relay], exports: []
end
