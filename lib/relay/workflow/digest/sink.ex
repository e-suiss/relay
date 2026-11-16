defmodule Relay.Workflow.Digest.Sink do
  @moduledoc """
  The receiver of what a digest window produced, configured as `config :relay, Relay.Workflow.Digest, sink: Module`: the workflow run engine, which resumes the run of the window's anchor notification. The sink is called inside the transaction that closes or cancels the window, so it writes its own records and jobs in the same transaction and calls nothing outside the database (INV-3).

  An outcome is `{:digest, info}` (two or more activities: send with the digest template and `info.render`), `{:single, info}` (one activity: send the anchor notification itself with its singular template, WF-27) or `{:cancelled, info}` (the recipient read the activities before the window fired). `info` carries `window_id`, `notification_id` and `delivery_id` of the anchor item.
  """

  @type info :: %{
          required(:window_id) => Relay.Id.t(),
          required(:notification_id) => Relay.Id.t() | nil,
          required(:delivery_id) => Relay.Id.t() | nil,
          optional(:render) => map()
        }
  @type outcome :: {:digest, info()} | {:single, info()} | {:cancelled, info()}

  @doc "Receives a digest outcome inside the closing transaction."
  @callback digest_ready(Relay.Scope.t(), outcome()) :: :ok
end
