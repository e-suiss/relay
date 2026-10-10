defmodule Relay.Policy do
  @moduledoc """
  Message classes, preferences, consent, İYS and quiet hours: the gate, filter and scheduler lattice. Other contexts use only the functions of this module.
  """

  use Boundary, top_level?: true, deps: [Relay], exports: []
end
