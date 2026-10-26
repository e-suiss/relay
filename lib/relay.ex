defmodule Relay do
  @moduledoc """
  Relay is the notification, messaging and event orchestration platform of Suiss. This module is the shared kernel boundary: the ports, types and runtime helpers every context may use.
  """

  use Boundary,
    deps: [],
    exports: [
      Clock,
      Random,
      Keys,
      Error,
      Redacted,
      Hygiene,
      Decision,
      Process,
      Config,
      Config.SecretFiles,
      Role,
      Repo,
      BulkRepo,
      QueueRepo,
      Scope,
      ScopeError,
      Actor,
      LogRedactor,
      Id,
      ExternalId,
      ExternalId.Type,
      Phone,
      Email,
      TimeZone,
      Locale,
      Environment,
      Region,
      RetentionClass,
      Crypto,
      Canonical,
      Jitter,
      ChannelParameters,
      Release,
      Worker,
      NetworkGuard,
      NetworkGuard.Error,
      Binary,
      TenantWorker
    ]
end
