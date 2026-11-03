defmodule Relay.Templates.CldrTest do
  use ExUnit.Case, async: true

  alias Relay.Templates.Cldr

  test "TP-56: the supported locales" do
    assert Cldr.supported_locales() == ~w(tr en de fr es it nl pt ar ru az)
    assert Relay.Templates.supported_locales() == Cldr.supported_locales()
  end

  test "TP-56: a locale formats with the tag of its language" do
    assert {:ok, %{cldr_locale_name: :tr}} = Cldr.language_tag("tr-TR")
    assert {:ok, %{cldr_locale_name: :pt}} = Cldr.language_tag("pt-BR")
    assert Cldr.language_tag("ja") == :error
  end

  test "TP-43: the backend warms every supported locale" do
    assert Cldr.warm_up() == :ok
    assert Relay.Templates.warm_up() == :ok
  end
end
