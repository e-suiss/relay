defmodule Relay.Api.TestPlane do
  @moduledoc """
  The ready-made content of every tenant's `test` plane (X-43, X-35, X-26): the seven seed recipients and the sample workflow. Both are set up by one job (`Relay.Api.TestPlane.Seeder`), queued when the tenant is created (`config :relay, Relay.Tenancy.Provisioning, test_plane: Relay.Api.TestPlane`) and again by the "reset seeds" action; the live plane never has them.

  The seed recipients are `Relay.Channels.seed_recipients/0`, whose addresses are in the fake provider's table. Setting them up is idempotent and puts back what each profile defines, so a manual change is undone by a reset:

    * every seed: its e-mail address, phone number, locale and time zone (`Europe/Istanbul`), no name, country or attributes, and the default delivery profile;
    * `seed_no_consent`: the consent copy says `none` on e-mail and SMS;
    * `seed_opted_out`: the consent copy says `revoked` on e-mail and SMS;
    * `seed_quiet_hours`: quiet hours cover every day from 00:00 to 00:00, e-mail included;
    * `seed_capped`: the global frequency cap is full for the global window from the setup (`Relay.Policy.Live.fill_frequency/3`);
    * `seed_bounced`: its e-mail address is suppressed with `hard_bounce`;
    * `seed_no_device`: no push device is registered by the setup;
    * `seed_fallback_timezone`: no time zone, so its sends use the fallback time zone.

  The sample workflow `welcome` of the `account` category (`transactional`) has an inbox step and an e-mail step on the `welcome` template, in English and Turkish; its event data is `first_name`. It is created and published only when the plane has no `welcome` workflow, so a tenant's own changes to it are kept.
  """

  @behaviour Relay.Tenancy.Provisioning

  alias Relay.Api.TestPlane.Seeder

  @workflow "welcome"
  @category "account"
  @template "welcome"
  @timezone "Europe/Istanbul"
  @locale "tr-TR"
  @days ~w(mon tue wed thu fri sat sun)
  @consent_seeds %{"seed_no_consent" => "none", "seed_opted_out" => "revoked"}
  @consent_channels ~w(email sms)

  @type answer :: {:ok, {100..599, [{String.t(), String.t()}], map()}} | {:error, Relay.Error.t()}

  # X-43
  # X-35
  @impl Relay.Tenancy.Provisioning
  @doc "Queues the setup of a tenant's test plane in a transaction of its own."
  @spec queue_seeds(Relay.Id.t()) :: :ok | {:error, Relay.Error.t()}
  def queue_seeds(<<_::128>> = tenant_id) do
    scope = Relay.Scope.new!(tenant_id, :test)

    case Relay.Preferences.in_scope(scope, fn _status -> Seeder.enqueue(scope) end) do
      {:ok, :ok} -> :ok
      {:ok, {:error, %Relay.Error{} = error}} -> {:error, error}
      _other -> {:error, unavailable()}
    end
  end

  # X-43
  @doc "Queues the reset of the seed recipients inside the request's transaction; `202`. Only in the test plane."
  @spec reset(Relay.Scope.t()) :: answer()
  def reset(%Relay.Scope{environment: :test} = scope) do
    case Seeder.enqueue(scope) do
      :ok -> {:ok, {202, [], %{"object" => "seed_reset", "status" => "queued"}}}
      {:error, _error} -> {:error, unavailable()}
    end
  end

  def reset(_scope), do: {:error, live()}

  # X-43
  @doc "Lists the seed recipients of the test plane with their addresses and whether each is set up."
  @spec list(Relay.Scope.t()) :: answer()
  def list(%Relay.Scope{environment: :test} = scope) do
    seeds = Relay.Channels.seed_recipients()

    case Relay.Subscribers.indexes(scope, Enum.map(seeds, & &1["seed"])) do
      {:ok, indexes} ->
        read = fn _status -> Enum.map(indexes, &Relay.Subscribers.resolve_indexes([&1])) end

        case Relay.Preferences.in_scope(scope, read) do
          {:ok, found} -> {:ok, {200, [], seed_list(seeds, found)}}
          {:error, _reason} -> {:error, unavailable()}
        end

      {:error, _reason} ->
        {:error, unavailable()}
    end
  end

  def list(_scope), do: {:error, live()}

  defp seed_list(seeds, found) do
    data =
      for {seed, ids} <- Enum.zip(seeds, found) do
        %{
          "object" => "seed_recipient",
          "external_id" => seed["seed"],
          "email" => seed["email"],
          "phone" => seed["phone"],
          "email_result" => seed["result"],
          "description" => seed["description"],
          "set_up" => ids != []
        }
      end

    %{"object" => "list", "data" => data, "has_more" => false, "next_cursor" => nil}
  end

  # X-43
  # X-35
  @doc "Sets up the sample workflow and the seed recipients of a `test` scope, outside any transaction; running it again puts the seeds back as defined and changes nothing else."
  @spec seed(Relay.Scope.t()) :: :ok | {:error, term()}
  def seed(%Relay.Scope{environment: :test} = scope) do
    {:ok, actor} = Relay.Actor.new(:system, "system:test_plane", "system:test_plane")

    with :ok <- sample(scope, actor) do
      Enum.reduce_while(Relay.Channels.seed_recipients(), :ok, fn seed, :ok ->
        case recipient(scope, seed, actor) do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, {seed["seed"], reason}}}
        end
      end)
    end
  end

  def seed(_scope), do: {:error, :live_plane}

  # X-35
  @doc "The key of the sample workflow."
  @spec sample_workflow() :: String.t()
  def sample_workflow, do: @workflow

  # X-35
  @doc "The definition of the sample workflow: an inbox step and an e-mail step."
  @spec sample_definition() :: map()
  def sample_definition do
    %{
      "name" => "Welcome",
      "category" => @category,
      "message_class" => "transactional",
      "event_schema" => %{
        "type" => "object",
        "properties" => %{"first_name" => %{"type" => "string", "maxLength" => 256}},
        "required" => ["first_name"]
      },
      "steps" => [
        %{"type" => "channel", "key" => "inbox", "channel" => "in_app", "template" => @template},
        %{"type" => "channel", "key" => "email", "channel" => "email", "template" => @template}
      ]
    }
  end

  defp sample(scope, actor) do
    case Relay.Workflow.resolve_published(scope, @workflow) do
      {:ok, {:ok, _published}} -> :ok
      {:ok, :not_found} -> with :ok <- template(scope, actor), do: workflow(scope, actor)
      {:ok, :not_published} -> publish(scope, actor)
      {:error, reason} -> {:error, reason}
    end
  end

  defp category do
    %{
      key: @category,
      name: "Account",
      message_class: "transactional",
      locked: false,
      enabled: true,
      channel_defaults: %{},
      default_expires_in: nil,
      frequency: nil,
      digest_allowed: false
    }
  end

  defp template(scope, actor) do
    at = %{key: @template, subtenant_id: nil}

    create = fn _status ->
      _ = Relay.Preferences.create_category(scope, category(), actor)

      case Relay.TemplateStore.template(@template, nil) do
        nil -> Relay.Api.Templates.create(scope, at, template_body(), actor)
        %{"live_version_no" => live} when is_integer(live) -> :live
        %{} -> :draft
      end
    end

    case Relay.TemplateStore.in_scope(scope, create) do
      {:ok, :live} -> :ok
      {:ok, {:error, error}} -> {:error, error}
      {:ok, _created_or_draft} -> publish_template(scope, at, actor)
      {:error, reason} -> {:error, reason}
    end
  end

  defp publish_template(scope, at, actor) do
    with {:ok, prepared} <-
           Relay.Api.Templates.prepare_publish(scope, at, %{"accept_warnings" => true}) do
      publish = fn _status ->
        %{"version" => version} = Relay.TemplateStore.template(@template, nil)
        Relay.Api.Templates.publish(scope, at, prepared, version, actor)
      end

      case Relay.TemplateStore.in_scope(scope, publish) do
        {:ok, {:ok, _answer}} -> :ok
        {:ok, {:error, error}} -> {:error, error}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp template_body do
    %{
      "key" => @template,
      "name" => "Welcome",
      "category" => @category,
      "definition" => %{
        "default_locale" => "en",
        "sensitivity" => "personal",
        "cells" => %{
          "in_app" => %{
            "en" => %{"title" => "Welcome", "body" => "Hello {{ first_name }}, welcome aboard."},
            "tr" => %{
              "title" => "Hoş geldiniz",
              "body" => "Merhaba {{ first_name }}, hoş geldiniz."
            }
          },
          "email" => %{
            "en" => email("Welcome", "Hello {{ first_name }}, welcome aboard."),
            "tr" => email("Hoş geldiniz", "Merhaba {{ first_name }}, hoş geldiniz.")
          }
        }
      }
    }
  end

  defp email(subject, text) do
    html =
      "<mjml><mj-body><mj-section><mj-column><mj-text>" <>
        text <> "</mj-text></mj-column></mj-section></mj-body></mjml>"

    %{"subject" => subject, "html" => html, "text" => text}
  end

  defp workflow(scope, actor) do
    create = fn _status -> Relay.Workflow.create(scope, @workflow, sample_definition(), actor) end

    case Relay.TemplateStore.in_scope(scope, create) do
      {:ok, {:ok, {:created, _id, _version}}} -> publish(scope, actor)
      other -> {:error, other}
    end
  end

  defp publish(scope, actor) do
    request = fn _status ->
      Relay.Workflow.request_publication(scope, @workflow, nil, "test plane sample", actor)
    end

    with {:ok, {:ok, {result, version_id}}} when result in [:pending, :already_pending] <-
           Relay.TemplateStore.in_scope(scope, request),
         {:ok, {:published, _errors}} <- Relay.Workflow.run_gate(scope, version_id) do
      :ok
    else
      other -> {:error, other}
    end
  end

  defp recipient(scope, seed, actor) do
    fields = %{
      "email" => seed["email"],
      "phone" => seed["phone"],
      "name" => nil,
      "locale" => @locale,
      "timezone" => if(seed["seed"] == "seed_fallback_timezone", do: nil, else: @timezone),
      "country" => nil,
      "attributes" => nil
    }

    with {:ok, plan} <- Relay.Api.Subscribers.prepare(scope, seed["seed"], fields, :replace),
         {:ok, id} <- upsert(scope, plan),
         :ok <- profile(scope, id, seed["seed"]),
         :ok <- consents(scope, id, seed["seed"]),
         :ok <- suppression(scope, seed, actor) do
      capped(scope, id, seed["seed"])
    end
  end

  defp upsert(scope, plan) do
    write = fn _status -> Relay.Subscribers.upsert(plan, nil) end

    case Relay.Preferences.in_scope(scope, write) do
      {:ok, {result, id, _version}} when result in [:created, :updated, :unchanged] -> {:ok, id}
      other -> {:error, other}
    end
  end

  defp profile(scope, id, seed) do
    profile = Map.merge(Relay.Preferences.default_profile(), seed_profile(seed))
    write = fn _status -> Relay.Preferences.write_profile(id, profile, "subscriber") end

    case Relay.Preferences.in_scope(scope, write) do
      {:ok, :ok} -> :ok
      other -> {:error, other}
    end
  end

  defp seed_profile("seed_quiet_hours") do
    ranges =
      for day <- @days,
          {from, to} <- [{"00:00", "12:00"}, {"12:00", "00:00"}],
          do: %{"day" => day, "start" => from, "end" => to}

    %{"quiet_hours" => ranges, "quiet_hours_email" => true}
  end

  defp seed_profile(_seed), do: %{}

  defp consents(scope, id, seed) do
    case Map.fetch(@consent_seeds, seed) do
      {:ok, status} -> consent_state(scope, id, seed, status)
      :error -> :ok
    end
  end

  defp consent_state(scope, id, seed, status) do
    with {:ok, current} <- Relay.Preferences.get_consents(scope, id) do
      missing = Enum.reject(@consent_channels, &in_state?(current, &1, status))

      Enum.reduce_while(missing, :ok, fn channel, :ok ->
        case record_consent(scope, id, seed, channel, status) do
          {:ok, _recorded} -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end
  end

  defp in_state?(current, channel, status) do
    Enum.any?(current, fn c ->
      c["channel"] == channel and c["status"] == status and is_nil(c["brand_subtenant_id"])
    end)
  end

  defp record_consent(scope, id, seed, channel, status) do
    now = Relay.Clock.utc_now()

    Relay.Preferences.record_consent(scope, %{
      recipient_id: id,
      brand_subtenant_id: nil,
      channel: channel,
      status: status,
      consent_kind: if(status == "none", do: "none", else: "explicit_opt_in"),
      recipient_type: "individual",
      source: "seed",
      sequence: DateTime.to_unix(now, :microsecond),
      occurred_at: now,
      text_version_digest: nil,
      evidence: nil,
      iys_transaction_ref: nil,
      source_event_ref: "seed:" <> seed,
      writer: "relay"
    })
  end

  defp suppression(scope, %{"seed" => "seed_bounced", "email" => email}, actor) do
    body = %{"channel" => "email", "address" => email, "reason" => "hard_bounce"}

    with {:ok, prepared} <- Relay.Api.Suppressions.prepare(scope, body) do
      add = fn _status -> Relay.Preferences.add_suppression(scope, prepared, actor) end

      case Relay.Preferences.in_scope(scope, add) do
        {:ok, {result, _id}} when result in [:added, :exists] -> :ok
        other -> {:error, other}
      end
    end
  end

  defp suppression(_scope, _seed, _actor), do: :ok

  defp capped(scope, id, "seed_capped" = seed) do
    case Relay.Policy.Live.fill_frequency(scope, id, seed) do
      :ok -> :ok
      :unavailable -> {:error, :frequency_counter_unavailable}
    end
  end

  defp capped(_scope, _id, _seed), do: :ok

  defp unavailable, do: Relay.Error.new(:service_unavailable, "try again")

  defp live do
    Relay.Error.new(:auth_environment_mismatch, "the seed recipients exist only in test")
  end
end
