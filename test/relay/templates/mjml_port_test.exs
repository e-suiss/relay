defmodule Relay.Templates.MjmlPortTest do
  use ExUnit.Case, async: true

  import Relay.Golden

  alias Relay.Templates.Mjml

  @moduletag :integration

  @executable Path.expand("../../../native/mjml_port/target/release/mjml_port", __DIR__)
  @fixtures Path.expand("../../golden/mjml", __DIR__)
  @open "<mjml><mj-body><mj-section><mj-column><mj-text>"
  @close "</mj-text></mj-column></mj-section></mj-body></mjml>"

  setup_all do
    assert File.exists?(@executable), "build the port program first: native/build.sh"
    sha256 = (@executable <> ".sha256") |> File.read!() |> String.split() |> hd()
    %{opts: [executable: @executable, sha256: sha256]}
  end

  defp text(body), do: @open <> body <> @close

  describe "TP-42 pinned MJML compiler" do
    for name <- ~w(basic liquid layout) do
      test "TP-42: #{name}.mjml compiles to its golden HTML", %{opts: opts} do
        source = File.read!(Path.join(@fixtures, "#{unquote(name)}.mjml"))
        assert {:ok, html} = Mjml.compile(source, opts)
        assert_golden("mjml/#{unquote(name)}.html", html)
      end
    end

    test "T-98: the same source always compiles to the same bytes", %{opts: opts} do
      source = File.read!(Path.join(@fixtures, "layout.mjml"))
      {:ok, first} = Mjml.compile(source, opts)

      for _ <- 1..3, do: assert(Mjml.compile(source, opts) == {:ok, first})
    end
  end

  describe "TP-8 MJML before Liquid" do
    test "TP-8: Liquid output and logic tags survive compilation verbatim", %{opts: opts} do
      liquid = [
        "{{ recipient.first_name }}",
        "{{ order.total | currency }}",
        "{% if order.total > 100 %}",
        "{% else %}",
        "{% endif %}",
        "{% for item in order.items %}",
        "{% endfor %}"
      ]

      assert {:ok, html} = Mjml.compile(text(Enum.join(liquid, " ")), opts)

      for tag <- liquid, do: assert(html =~ tag, tag)
    end

    test "TP-8: Liquid in attributes survives compilation verbatim", %{opts: opts} do
      source = File.read!(Path.join(@fixtures, "liquid.mjml"))
      assert {:ok, html} = Mjml.compile(source, opts)
      assert html =~ ~s(href="{{ links.order }}")
      assert html =~ ~s(src="{{ brand.logo_url }}")
    end
  end

  describe "T-98 limits" do
    test "T-98: mj-include is refused with its position", %{opts: opts} do
      source = "<mjml>\n<mj-body>\n  <mj-include path=\"./partial.mjml\" />\n</mj-body>\n</mjml>"

      assert {:error, %Relay.Error{code: :mjml_include, details: %{line: 3, column: 3}}} =
               Mjml.compile(source, opts)

      head = ~s(<mjml><mj-head><mj-include path="/etc/passwd" type="css" /></mj-head></mjml>)
      assert {:error, %Relay.Error{code: :mjml_include}} = Mjml.compile(head, opts)
    end

    test "T-98: malformed MJML is a parse error", %{opts: opts} do
      for source <- ["<mjml><mj-body><mj-section>", "plain text", "<mjml></mj-body></mjml>"] do
        assert {:error, %Relay.Error{code: :mjml_parse, message: message}} =
                 Mjml.compile(source, opts)

        assert message != ""
      end
    end

    test "T-98: output above the limit is refused", %{opts: opts} do
      assert {:error, %Relay.Error{code: :mjml_output_too_large}} =
               Mjml.compile(text("hello"), Keyword.put(opts, :max_output, 64))
    end

    test "TP-6: input above 256 KiB is refused", %{opts: opts} do
      big = text(String.duplicate("a", 256 * 1024))

      assert {:error, %Relay.Error{code: :mjml_input_too_large}} = Mjml.compile(big, opts)
    end

    test "T-98: invalid UTF-8 is refused", %{opts: opts} do
      assert {:error, %Relay.Error{code: :mjml_encoding}} =
               Mjml.compile(<<"<mjml>", 0xFF, "</mjml>">>, opts)
    end
  end
end
