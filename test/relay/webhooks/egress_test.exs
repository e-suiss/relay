defmodule Relay.Webhooks.EgressTest.FakeResolver do
  @behaviour Relay.Webhooks.Egress.Resolver

  @impl Relay.Webhooks.Egress.Resolver
  def resolve(host, timeout_ms) do
    send(self(), {:resolved, host, timeout_ms})

    case Process.get({:dns, host}, []) do
      [] -> {:error, :nxdomain}
      [answer] -> answer
      [answer | rest] -> next(host, answer, rest)
    end
  end

  defp next(host, answer, rest) do
    Process.put({:dns, host}, rest)
    answer
  end
end

defmodule Relay.Webhooks.EgressTest.FakeTransport do
  @behaviour Relay.Webhooks.Egress.Transport

  @ok {:ok, %{status: 200, headers: [{"x-served", "yes"}], body: "ok", truncated: false}}

  @impl Relay.Webhooks.Egress.Transport
  def request(connection, request) do
    send(self(), {:connected, connection, request})
    Map.get(Process.get(:answers, %{}), connection.address, @ok)
  end
end

defmodule Relay.Webhooks.EgressTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Relay.Webhooks.Egress
  alias Relay.Webhooks.Egress.Address
  alias Relay.Webhooks.Egress.Blocklist
  alias Relay.Webhooks.Egress.Policy
  alias Relay.Webhooks.EgressTest.FakeResolver
  alias Relay.Webhooks.EgressTest.FakeTransport

  @options [
    connect_timeout_ms: 5_000,
    total_timeout_ms: 20_000,
    max_response_bytes: 8_192,
    resolver: FakeResolver,
    transport: FakeTransport
  ]
  @host "hooks.example.com"
  @url "https://hooks.example.com/relay?source=a"
  @public {203, 0, 114, 10}
  @other {198, 51, 101, 7}
  @blocked_ranges ~w(
    0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12 192.0.0.0/24
    192.0.2.0/24 192.168.0.0/16 198.18.0.0/15 198.51.100.0/24 203.0.113.0/24 224.0.0.0/4
    240.0.0.0/4 255.255.255.255/32 ::/128 ::1/128 ::ffff:0:0/96 64:ff9b::/96 100::/64
    2001:db8::/32 fc00::/7 fe80::/10 ff00::/8
  )
  @metadata_addresses ~w(
    169.254.169.254 169.254.170.2 168.63.129.16 100.100.100.200 192.0.0.192 fd00:ec2::254
    fe80::a9fe:a9fe
  )
  @metadata_hosts ~w(metadata.google.internal metadata.goog metadata.azure.internal instance-data)

  defp policy(opts \\ []) do
    {:ok, policy} = Policy.new(Keyword.put_new(opts, :deployment, :saas))
    policy
  end

  defp dns(host, answers), do: Process.put({:dns, host}, answers)

  defp post(policy, url, headers \\ []) do
    request = %{method: "POST", url: url, headers: headers, body: "{}"}
    Egress.request(policy, request, @options)
  end

  defp ip(text) do
    {:ok, ip} = Address.parse(text)
    ip
  end

  defp check(policy, text), do: Policy.check_address(policy, ip(text), @host)

  defp edges(text) do
    {:ok, {family, base, prefix}} = Address.parse_cidr(text)
    size = if family == 4, do: 32, else: 128
    last = base + Integer.pow(2, size - prefix) - 1
    [address(family, base), address(family, last)]
  end

  defp address(4, value) do
    <<a, b, c, d>> = <<value::32>>
    {a, b, c, d}
  end

  defp address(6, value) do
    <<a::16, b::16, c::16, d::16, e::16, f::16, g::16, h::16>> = <<value::128>>
    {a, b, c, d, e, f, g, h}
  end

  defp data(name) do
    [:code.priv_dir(:relay), "webhooks", name] |> Path.join() |> File.read!() |> Jason.decode!()
  end

  defp octet, do: integer(0..255)

  describe "WH-40 registration rules" do
    test "WH-40: only https is accepted, and no option of the policy changes that" do
      for policy <- [policy(), policy(deployment: :self_hosted, allow_list: ["10.0.0.0/8"])] do
        assert {:ok, %{host: @host, port: 443, path: "/relay?source=a", literal: nil}} =
                 Egress.validate_url(policy, @url)

        for url <- ["http://hooks.example.com/relay", "ftp://hooks.example.com/", @host] do
          assert Egress.validate_url(policy, url) == {:error, :scheme_not_https}
        end
      end
    end

    test "WH-40: the port is 443, or a port the installation allows" do
      assert {:error, :port_not_allowed} = Egress.validate_url(policy(), "https://#{@host}:8443/")
      assert {:error, :port_not_allowed} = Egress.validate_url(policy(), "https://#{@host}:80/")
      assert {:ok, %{port: 443}} = Egress.validate_url(policy(), "https://#{@host}:443/")

      allowed = policy(extra_ports: [8443])
      assert {:ok, %{port: 8443}} = Egress.validate_url(allowed, "https://#{@host}:8443/")
      assert {:ok, %{port: 443}} = Egress.validate_url(allowed, "https://#{@host}/")
      assert {:error, :port_not_allowed} = Egress.validate_url(allowed, "https://#{@host}:9443/")

      for ports <- [[0], [65_536], ["8443"], :any] do
        assert Policy.new(deployment: :saas, extra_ports: ports) == {:error, :invalid_port}
      end
    end

    test "WH-40: a URL with user information is refused" do
      for url <- ["https://user:pass@#{@host}/", "https://user@#{@host}/"] do
        assert Egress.validate_url(policy(), url) == {:error, :userinfo_not_allowed}
      end
    end

    test "WH-40: the host is a plain DNS name or a strictly written address" do
      valid = &Egress.validate_url(policy(), &1)

      assert {:ok, %{host: @host, path: "/"}} = valid.("https://Hooks.Example.COM")
      assert {:ok, %{host: @host, path: "/x"}} = valid.("https://hooks.example.com./x#top")
      assert {:ok, %{host: "xn--bcher-kva.example"}} = valid.("https://xn--bcher-kva.example/")

      refused = [
        "https://2130706433/",
        "https://0x7f.0.0.1/",
        "https://127.1/",
        "https://0177.0.0.1/",
        "https://hooks_internal.example.com/",
        "https://-hooks.example.com/",
        "https://intranet/",
        "https:///relay",
        "https://hooks.example.com\\@internal.example/",
        "https://hooks example.com/",
        "https://bücher.example/",
        "https://" <> String.duplicate("a", 64) <> ".example.com/",
        "",
        nil
      ]

      for url <- refused do
        assert {:error, reason} = Egress.validate_url(policy(), url)
        assert reason in [:invalid_url, :invalid_host]
      end
    end

    test "WH-40: the DNS check at registration is feedback only" do
      dns(@host, [{:ok, [@public, {10, 0, 0, 5}, {0, 0, 0, 0, 0, 0xFFFF, 0x7F00, 1}]}])
      options = [dns_timeout_ms: 2_000, resolver: FakeResolver]

      findings = [
        {:blocked_address, "10.0.0.5", "private"},
        {:blocked_address, "127.0.0.1", "loopback"}
      ]

      assert Egress.dns_findings(policy(), @url, options) == {:ok, findings}

      assert_received {:resolved, @host, 2_000}

      dns(@host, [{:ok, [@public]}])
      assert Egress.dns_findings(policy(), @url, options) == {:ok, []}

      dns(@host, [])
      assert Egress.dns_findings(policy(), @url, options) == {:ok, [{:unresolved, :nxdomain}]}

      assert Egress.dns_findings(policy(), "https://203.0.114.10/", options) == {:ok, []}

      assert Egress.dns_findings(policy(), "http://a.example/", options) ==
               {:error, :scheme_not_https}
    end

    test "WH-40: a name that passed the check at registration is still validated when the connection is made" do
      dns(@host, [{:ok, [@public]}, {:ok, [{192, 168, 1, 5}]}])
      options = [dns_timeout_ms: 2_000, resolver: FakeResolver]

      assert Egress.dns_findings(policy(), @url, options) == {:ok, []}

      assert {:error, %{class: :blocked, reason: "private", address: "192.168.1.5"}} =
               post(policy(), @url)

      refute_received {:connected, _connection, _request}
    end
  end

  describe "WH-41 validation when the connection is made" do
    test "WH-41: the blocked ranges are the data the release ships" do
      ranges = data("blocked_ranges.json")["ranges"]
      metadata = data("metadata.json")

      assert Enum.map(ranges, & &1["cidr"]) == @blocked_ranges
      assert metadata["addresses"] == @metadata_addresses
      assert metadata["hosts"] == @metadata_hosts
      assert length(Blocklist.default().ranges) == length(@blocked_ranges)
    end

    test "WH-41: the first and the last address of every blocked range are refused" do
      for range <- @blocked_ranges, address <- edges(range) do
        assert {:blocked, _name} = Policy.check_address(policy(), address, @host)
      end
    end

    test "WH-41: addresses next to the blocked ranges pass" do
      passing = ~w(
        8.8.8.8 9.255.255.255 11.0.0.0 100.63.255.255 100.128.0.0 126.255.255.255 128.0.0.0
        169.253.255.255 169.255.0.0 172.15.255.255 172.32.0.0 192.0.1.0 192.0.3.0 192.167.255.255
        192.169.0.0 198.17.255.255 198.20.0.0 198.51.99.255 198.51.101.0 203.0.112.255 203.0.114.0
        223.255.255.255 2606:4700::1111 2001:db7:ffff::1 2001:db9::1 fbff::1 fe7f::1 fec0::1
      )

      for address <- passing do
        assert check(policy(), address) == :ok
      end
    end

    property "WH-41: an IPv4-mapped IPv6 address gets the verdict of the IPv4 address it carries" do
      policy = policy()

      check all a <- octet(), b <- octet(), c <- octet(), d <- octet() do
        mapped = {0, 0, 0, 0, 0, 0xFFFF, a * 256 + b, c * 256 + d}

        assert Address.canonical(mapped) == {a, b, c, d}

        assert Policy.check_address(policy, mapped, @host) ==
                 Policy.check_address(policy, {a, b, c, d}, @host)
      end
    end

    test "WH-41: an IPv4 address inside an IPv6 transition address is validated as well" do
      assert check(policy(), "::ffff:10.0.0.1") == {:blocked, "private"}
      assert check(policy(), "::ffff:127.0.0.1") == {:blocked, "loopback"}
      assert check(policy(), "::ffff:8.8.8.8") == :ok
      assert check(policy(), "64:ff9b::808:808") == {:blocked, "nat64"}
      assert check(policy(), "2002:808:808::1") == :ok
      assert check(policy(), "2002:a00:1::1") == {:blocked, "private"}
      assert check(policy(), "2002:a9fe:a9fe::1") == {:blocked, "cloud_metadata"}
      assert check(policy(), "2001:0:7f00:1::1") == {:blocked, "loopback"}
      assert check(policy(), "2001:0:808:808::f7f7:f7f7") == :ok
      assert check(policy(), "2001:0:808:808::f5ff:fffe") == {:blocked, "private"}
      assert check(policy(), "::10.0.0.1") == {:blocked, "private"}
      assert check(policy(), "64:ff9b:1::a00:1") == {:blocked, "private"}
    end

    test "WH-41: addresses are read strictly, so no other spelling reaches a blocked address" do
      loose = ~w(127.1 0177.0.0.1 0x7f.0.0.1 1.2.3 1.2.3.4.5 256.1.1.1 01.2.3.4 fe80::1%eth0 ::g)

      for text <- loose do
        assert Address.parse(text) == :error
      end

      assert Address.parse(" 1.2.3.4") == :error
      assert Address.parse("1.2.3.4") == {:ok, {1, 2, 3, 4}}
      assert Address.parse("::ffff:1.2.3.4") == {:ok, {0, 0, 0, 0, 0, 0xFFFF, 0x0102, 0x0304}}

      assert Address.parse_cidr("10.9.8.7/8") == Address.parse_cidr("10.0.0.0/8")
      assert Address.parse_cidr("10.0.0.5") == Address.parse_cidr("10.0.0.5/32")

      for text <- ~w(10.0.0.0/33 ::/129 10.0.0.0/08 10.0.0.0/ 10.0.0.0/8/8 example.com/8) do
        assert Address.parse_cidr(text) == :error
      end
    end

    test "WH-41: cloud metadata addresses are refused, also outside the blocked ranges" do
      for address <- @metadata_addresses do
        assert check(policy(), address) == {:blocked, "cloud_metadata"}
      end

      assert Blocklist.match(Blocklist.default(), ip("168.63.129.15")) == nil
    end

    test "WH-41: a metadata host name is refused before anything is resolved" do
      urls = [
        "https://metadata.google.internal/computeMetadata/v1/",
        "https://METADATA.GOOG./",
        "https://metadata.azure.internal/",
        "https://instance-data/latest/meta-data/",
        "https://instance-data.eu-west-1.compute.internal/",
        "https://a.metadata.google.internal/"
      ]

      for url <- Enum.take(urls, 4) ++ [List.last(urls)] do
        assert Egress.validate_url(policy(), url) == {:error, :metadata_host}

        assert {:error, %{class: :blocked, reason: "metadata_host", address: nil}} =
                 post(policy(), url)
      end

      refute_received {:resolved, _host, _timeout_ms}
      refute_received {:connected, _connection, _request}
      assert {:ok, _target} = Egress.validate_url(policy(), Enum.at(urls, 4))
    end

    test "WH-41: the connection goes to the validated address, with the original host name" do
      dns(@host, [{:ok, [@public]}])
      headers = [{"webhook-id", "evt_1"}, {"Host", "internal.example"}, {"Content-Length", "999"}]

      assert {:ok, response} = post(policy(), @url, headers)
      assert %{status: 200, body: "ok", truncated: false, address: "203.0.114.10"} = response
      assert response.duration_ms >= 0

      assert_received {:resolved, @host, 5_000}
      assert_received {:connected, connection, request}
      assert %{address: @public, host: @host, port: 443, proxy: nil} = connection
      assert %{connect_timeout_ms: 5_000, max_response_bytes: 8_192} = connection
      assert connection.total_timeout_ms in 1..20_000
      assert request.path == "/relay?source=a"
      assert request.headers == [{"webhook-id", "evt_1"}, {"connection", "close"}]
    end

    test "WH-41: a name that changes its address after validation cannot move the connection" do
      dns(@host, [{:ok, [@public]}, {:ok, [{169, 254, 169, 254}]}])

      assert {:ok, %{address: "203.0.114.10"}} = post(policy(), @url)
      assert_received {:resolved, @host, _timeout_ms}
      refute_received {:resolved, _host, _timeout_ms}
      assert_received {:connected, %{address: @public, host: @host}, _request}

      assert {:error, %{class: :blocked, reason: "cloud_metadata", address: "169.254.169.254"}} =
               post(policy(), @url)

      refute_received {:connected, _connection, _request}
    end

    test "WH-41: every address of the name is validated, and one blocked address refuses the request" do
      refused = [{10, 0, 0, 5}, {0, 0, 0, 0, 0, 0xFFFF, 0x7F00, 1}, {0xFE80, 0, 0, 0, 0, 0, 0, 1}]

      for blocked <- refused do
        dns(@host, [{:ok, [@public, blocked, @other]}])

        assert {:error, %{class: :blocked, address: address}} = post(policy(), @url)
        assert address == Address.to_text(Address.canonical(blocked))
        refute_received {:connected, _connection, _request}
      end
    end

    test "WH-41: an address written in the URL is validated without DNS" do
      literals = ~w(https://10.0.0.5/ https://[::1]/ https://[::ffff:127.0.0.1]/ https://0.0.0.0/)

      for url <- literals do
        assert Egress.validate_url(policy(), url) == {:error, :blocked_address}
        assert {:error, %{class: :blocked, reason: "blocked_address"}} = post(policy(), url)
      end

      assert {:ok, %{address: "203.0.114.10"}} = post(policy(), "https://203.0.114.10/hook")
      assert_received {:connected, %{address: @public, host: "203.0.114.10"}, %{path: "/hook"}}
      refute_received {:resolved, _host, _timeout_ms}
    end

    test "WH-41: a name that does not resolve is a DNS failure, and no connection is made" do
      assert {:error, %{class: :dns, reason: "nxdomain", address: nil}} = post(policy(), @url)

      dns(@host, [{:error, :timeout}])
      assert {:error, %{class: :dns, reason: "timeout"}} = post(policy(), @url)

      dns(@host, [{:ok, []}])
      assert {:error, %{class: :dns, reason: "no_address"}} = post(policy(), @url)
      refute_received {:connected, _connection, _request}
    end

    test "WH-41: when a validated address refuses the connection the next validated address is tried" do
      refused = {:error, %{class: :connect, reason: "econnrefused"}}
      dns(@host, [{:ok, [{0x2606, 0x4700, 0, 0, 0, 0, 0, 0x1111}, @public, @other]}])
      Process.put(:answers, %{@public => refused})

      assert {:ok, %{address: "198.51.101.7"}} = post(policy(), @url)
      assert_received {:connected, %{address: @public}, _request}
      assert_received {:connected, %{address: @other}, _request}
      refute_received {:connected, _connection, _request}

      Process.put(:answers, %{@public => {:error, %{class: :timeout, reason: "timeout"}}})
      assert {:error, %{class: :timeout, address: "203.0.114.10"}} = post(policy(), @url)

      Process.put(:answers, %{@public => refused, @other => refused})
      dns(@host, [{:ok, [@public, @other]}])
      assert {:error, %{class: :connect, address: "198.51.101.7"}} = post(policy(), @url)
    end

    test "WH-41: an installation can add to the blocklist and take nothing away" do
      additions = %{
        ranges: ["203.0.114.0/24"],
        metadata_addresses: ["198.51.101.7"],
        metadata_hosts: ["Metadata.Internal.Example"]
      }

      assert {:ok, blocklist} = Blocklist.extend(Blocklist.default(), additions)
      policy = policy(blocklist: blocklist)

      assert check(policy, "203.0.114.10") == {:blocked, "installation"}
      assert check(policy, "198.51.101.7") == {:blocked, "cloud_metadata"}
      assert check(policy, "10.0.0.5") == {:blocked, "private"}
      assert check(policy, "169.254.169.254") == {:blocked, "cloud_metadata"}
      assert check(policy, "8.8.8.8") == :ok

      assert Egress.validate_url(policy, "https://metadata.internal.example/") ==
               {:error, :metadata_host}

      assert Egress.validate_url(policy, "https://metadata.goog/") == {:error, :metadata_host}

      invalid = [%{ranges: ["10.0.0.0/40"]}, %{metadata_addresses: ["host"]}, %{ranges: [1]}]

      for additions <- invalid do
        assert {:error, {:invalid_entry, _entry}} = Blocklist.extend(blocklist, additions)
      end
    end
  end

  describe "WH-42 WH-43 one boundary for every outbound path" do
    test "WH-42: a redirect is returned as the response it is and never followed" do
      dns(@host, [{:ok, [@public]}])
      redirect = %{status: 302, body: "", truncated: false}
      headers = [{"location", "https://169.254.169.254/latest/meta-data/"}]
      Process.put(:answers, %{@public => {:ok, Map.put(redirect, :headers, headers)}})

      assert {:ok, %{status: 302, headers: ^headers, address: "203.0.114.10"}} =
               post(policy(), @url)

      assert_received {:connected, %{address: @public}, _request}
      refute_received {:connected, _connection, _request}
      refute_received {:resolved, "169.254.169.254", _timeout_ms}
    end

    test "WH-43: the boundary takes any request, so token endpoints and broker addresses pass through the same rules" do
      dns("login.example.com", [{:ok, [{172, 16, 0, 9}]}])
      request = %{method: "GET", url: "https://login.example.com/token", headers: [], body: ""}

      assert {:error, %{class: :blocked, reason: "private", address: "172.16.0.9"}} =
               Egress.request(policy(), request, @options)

      plain = %{request | url: "http://login.example.com/token"}

      assert {:error, %{class: :invalid, reason: "scheme_not_https"}} =
               Egress.request(policy(), plain, @options)
    end

    test "WH-43: a header that could split the request is refused before anything is resolved" do
      headers = [{"x-event", "a\r\nhost: internal"}, {"x event", "a"}, {"x-event", 1}, :bad]

      for header <- headers do
        assert {:error, %{class: :invalid, reason: "invalid_header"}} =
                 post(policy(), @url, [header])
      end

      refute_received {:resolved, _host, _timeout_ms}
    end

    test "WH-43: mTLS, private CA certificates and an egress proxy reach the transport as given" do
      dns(@host, [{:ok, [@public]}])
      certificate = %{certificate: <<1, 2, 3>>, key: Relay.Redacted.wrap({:ECPrivateKey, <<4>>})}
      proxy = {:http, "egress.example.net", 3128}
      extra = [client_certificate: certificate, ca_certificates: [<<5>>], proxy: proxy]
      request = %{method: "POST", url: @url, headers: [], body: "{}"}

      assert {:ok, _response} = Egress.request(policy(), request, @options ++ extra)
      assert_received {:connected, connection, _request}
      assert connection.client_certificate == certificate
      assert connection.ca_certificates == [<<5>>]
      assert connection.proxy == proxy
      assert connection.address == @public
    end
  end

  describe "WH-44 internal destinations of a self-hosted installation" do
    test "WH-44: an internal address is refused by default and opened only by the installation allow-list" do
      dns("erp.corp.example", [{:ok, [{10, 0, 0, 5}]}])
      dns("crm.corp.example", [{:ok, [{10, 0, 1, 5}]}])
      url = "https://erp.corp.example/hooks"

      assert {:error, %{class: :blocked, reason: "private"}} =
               post(policy(deployment: :self_hosted), url)

      allowed = policy(deployment: :self_hosted, allow_list: ["10.0.0.0/24"])
      assert {:ok, %{address: "10.0.0.5"}} = post(allowed, url)
      assert_received {:connected, %{address: {10, 0, 0, 5}, host: "erp.corp.example"}, _request}

      assert {:error, %{class: :blocked, address: "10.0.1.5"}} =
               post(allowed, "https://crm.corp.example/hooks")

      assert {:ok, _target} = Egress.validate_url(allowed, "https://10.0.0.7/")
      assert Egress.validate_url(allowed, "https://10.0.1.7/") == {:error, :blocked_address}
    end

    test "WH-44: a host entry exempts only the addresses of that host" do
      dns("erp.corp.example", [{:ok, [{192, 168, 1, 5}]}])
      dns("other.corp.example", [{:ok, [{192, 168, 1, 5}]}])
      dns("erp", [{:ok, [{192, 168, 1, 6}]}])
      allowed = policy(deployment: :self_hosted, allow_list: ["ERP.corp.example.", "erp"])

      assert {:ok, %{address: "192.168.1.5"}} = post(allowed, "https://erp.corp.example/hooks")
      assert {:ok, %{address: "192.168.1.6"}} = post(allowed, "https://erp/hooks")

      assert {:error, %{class: :blocked, reason: "private"}} =
               post(allowed, "https://other.corp.example/hooks")
    end

    test "WH-44: loopback and cloud metadata can never be allow-listed" do
      entries = ~w(
        127.0.0.0/8 127.0.0.1 127.9.9.9/32 ::1 ::/0 0.0.0.0/0 169.254.0.0/16 169.254.169.254
        168.63.129.16/32 100.100.0.0/16 192.0.0.0/24 fd00:ec2::/32 fe80::/10
        metadata.google.internal instance-data
      )

      for entry <- entries do
        assert Policy.new(deployment: :self_hosted, allow_list: ["10.0.0.0/8", entry]) ==
                 {:error, {:not_allow_listable, entry}}
      end
    end

    test "WH-44: the allow-list does not remove the validation when the connection is made" do
      allowed = policy(deployment: :self_hosted, allow_list: ["erp.corp.example", "10.0.0.0/8"])

      refused = [{{127, 0, 0, 1}, "loopback"}, {{169, 254, 169, 254}, "cloud_metadata"}]

      for {address, reason} <- refused do
        dns("erp.corp.example", [{:ok, [{10, 0, 0, 5}, address]}])

        assert {:error, %{class: :blocked, reason: ^reason}} =
                 post(allowed, "https://erp.corp.example/hooks")
      end

      refute_received {:connected, _connection, _request}
    end

    test "WH-44: a SaaS installation has no allow-list" do
      assert Policy.new(deployment: :saas, allow_list: ["10.0.0.0/8"]) ==
               {:error, :allow_list_not_available}

      assert {:ok, %Policy{allow_ranges: [], allow_hosts: []}} = Policy.new(deployment: :saas)
      assert_raise KeyError, fn -> Policy.new(allow_list: []) end
    end

    test "WH-44: an entry that is neither a range nor a host name is refused" do
      for entry <- ["10.0.0.0/40", "not a host", "under_score.example", 10] do
        assert {:error, {:invalid_entry, _entry}} =
                 Policy.new(deployment: :self_hosted, allow_list: [entry])
      end
    end
  end
end
