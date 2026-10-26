defmodule Relay.Platform.FanoutSource do
  @moduledoc """
  The audience behind a fan-out (a campaign audience, the members of a topic, a batch). A source pages recipient identifiers by keyset inside a slice's range and processes one sub-batch of them; both calls run inside the sub-batch's scoped transaction, so the records the sub-batch writes commit together with its checkpoint (T-23). A source never loads the whole audience and never uses `OFFSET`.

  Sources are configured by kind: `config :relay, Relay.Platform.Fanout, sources: %{"campaign" => Module}`.
  """

  @typedoc "Where the next page starts: after the last processed identifier, or from the slice's inclusive lower bound (`nil` = unbounded)."
  @type position :: {:after, Relay.Id.t()} | {:from, Relay.Id.t() | nil}

  @doc "Returns at most `limit` recipient identifiers of the fan-out in ascending order, starting at `position` and below `range_to` (`nil` = unbounded)."
  @callback page(
              Relay.Scope.t(),
              fanout :: map(),
              position(),
              range_to :: Relay.Id.t() | nil,
              limit :: pos_integer()
            ) :: [Relay.Id.t()]

  @doc "Processes one sub-batch and returns how many recipients were processed and how many failed."
  @callback process(Relay.Scope.t(), fanout :: map(), [Relay.Id.t(), ...]) ::
              {non_neg_integer(), non_neg_integer()}
end
