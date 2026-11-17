defmodule Relay.Operators.StepUpLevelTest do
  use ExUnit.Case, async: false

  alias Relay.Operators.Access
  alias Relay.Operators.Session

  @aal1 "http://idmanagement.gov/ns/assurance/aal/1"
  @aal2 "http://idmanagement.gov/ns/assurance/aal/2"
  @aal3 "http://idmanagement.gov/ns/assurance/aal/3"

  setup do
    config = Application.get_env(:relay, Access, [])
    on_exit(fn -> Application.put_env(:relay, Access, config) end)
    %{config: config}
  end

  defp threshold(ctx, aal),
    do: Application.put_env(:relay, Access, Keyword.put(ctx.config, :step_up_aal, aal))

  defp session(acr) do
    %Session{
      operator_id: Relay.Id.generate(),
      subject: "operator-1",
      client_kind: :panel,
      grants: [],
      acr: acr,
      step_up_at: Relay.Clock.utc_now(),
      step_up_ref: "stepup-1"
    }
  end

  describe "E-105 TN-21 step-up level" do
    test "E-105: a step-up asks Access for AAL2 by its acr value" do
      assert Access.step_up_aal() == 2
      assert Access.step_up_acr() == @aal2
      assert Relay.Operators.step_up_required().details.step_up.acr_values == @aal2
    end

    test "TN-21: AAL1 is refused, AAL2 and AAL3 are accepted by rank" do
      refute Relay.Operators.step_up_fresh?(session(@aal1))
      assert Relay.Operators.step_up_fresh?(session(@aal2))
      assert Relay.Operators.step_up_fresh?(session(@aal3))
    end

    test "E-105: a value that is not an Access level never satisfies the step-up" do
      for acr <- [nil, "", "urn:suiss:acr:step-up", "step_up", @aal2 <> "0", "aal2"] do
        refute Access.acr_satisfied?(acr), inspect(acr)
      end

      assert Access.acr_satisfied?("urn:other " <> @aal3)
    end

    test "E-105: the installation raises the threshold to AAL3 and then AAL2 is refused", ctx do
      threshold(ctx, 3)
      assert Access.step_up_acr() == @aal3
      refute Relay.Operators.step_up_fresh?(session(@aal2))
      assert Relay.Operators.step_up_fresh?(session(@aal3))
    end

    test "E-105: a threshold below AAL2 is not taken", ctx do
      threshold(ctx, 1)
      assert Access.step_up_aal() == 2
      refute Relay.Operators.step_up_fresh?(session(@aal1))
    end
  end
end
