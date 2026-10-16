defmodule Relay.RetentionClassTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Relay.RetentionClass

  @access_classes ~w(profile kyc transaction aml_report audit traffic consent message_log contract
                     ledger tax dsr_log erasure_log suppression work_record work_evidence work_draft
                     agent_trace one_memory one_model one_observation one_sensitive
                     one_provider_trace one_browser_profile one_training_lineage)a

  describe "OP-17 OP-18 retention classes" do
    test "OP-18: every Relay class maps to the Access Appendix C classes of the table" do
      assert Map.new(RetentionClass.all(), &{&1, RetentionClass.access_classes(&1)}) == %{
               recipient_profile: [:profile],
               notification_content: [:profile],
               delivery_record: [:message_log],
               commercial_message_record: [:consent, :message_log],
               preference: [:profile],
               audit: [:audit],
               traffic: [:traffic],
               suppression: [:suppression],
               dsr_log: [:dsr_log],
               erasure_log: [:erasure_log]
             }
    end

    test "OP-17: every mapped class is an Access Appendix C class" do
      for class <- RetentionClass.all(), access <- RetentionClass.access_classes(class) do
        assert access in @access_classes
      end
    end

    test "OP-24: data subject requests and erasures have their own classes" do
      assert :dsr_log in RetentionClass.all()
      assert :erasure_log in RetentionClass.all()
    end

    test "OP-18: text forms round-trip" do
      for class <- RetentionClass.all() do
        assert RetentionClass.cast(RetentionClass.dump(class)) == {:ok, class}
      end
    end

    property "OP-18: unknown classes are refused" do
      known = Enum.map(RetentionClass.all(), &Atom.to_string/1)

      check all name <- string(:printable), name not in known do
        assert {:error, %Relay.Error{code: :invalid_retention_class}} = RetentionClass.cast(name)
      end
    end
  end
end
