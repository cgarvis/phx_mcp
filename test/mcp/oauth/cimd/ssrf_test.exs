defmodule MCP.OAuth.CIMD.SSRFTest do
  use ExUnit.Case, async: true

  alias MCP.OAuth.CIMD.SSRF

  describe "disallowed?/1 -- IPv4" do
    test "rejects loopback" do
      assert SSRF.disallowed?({127, 0, 0, 1})
    end

    test "rejects RFC1918 private ranges" do
      assert SSRF.disallowed?({10, 0, 0, 1})
      assert SSRF.disallowed?({172, 16, 0, 1})
      assert SSRF.disallowed?({172, 31, 255, 255})
      assert SSRF.disallowed?({192, 168, 1, 1})
    end

    test "rejects the cloud instance-metadata address" do
      assert SSRF.disallowed?({169, 254, 169, 254})
    end

    test "rejects CGNAT range" do
      assert SSRF.disallowed?({100, 64, 0, 1})
    end

    test "rejects multicast and reserved" do
      assert SSRF.disallowed?({224, 0, 0, 1})
      assert SSRF.disallowed?({255, 255, 255, 255})
    end

    test "allows plausibly-public unicast addresses" do
      refute SSRF.disallowed?({93, 184, 216, 34})
      refute SSRF.disallowed?({8, 8, 8, 8})
    end

    test "172.15.x.x and 172.32.x.x are outside the private /12, not rejected by that rule" do
      refute SSRF.disallowed?({172, 15, 0, 1})
      refute SSRF.disallowed?({172, 32, 0, 1})
    end
  end

  describe "disallowed?/1 -- IPv6" do
    test "rejects loopback and unspecified" do
      assert SSRF.disallowed?({0, 0, 0, 0, 0, 0, 0, 1})
      assert SSRF.disallowed?({0, 0, 0, 0, 0, 0, 0, 0})
    end

    test "rejects unique-local fc00::/7 (includes the AWS IPv6 metadata address)" do
      assert SSRF.disallowed?({0xFD00, 0xEC2, 0, 0, 0, 0, 0, 0x254})
      assert SSRF.disallowed?({0xFC00, 0, 0, 0, 0, 0, 0, 1})
    end

    test "rejects link-local fe80::/10" do
      assert SSRF.disallowed?({0xFE80, 0, 0, 0, 0, 0, 0, 1})
    end

    test "rejects multicast ff00::/8" do
      assert SSRF.disallowed?({0xFF02, 0, 0, 0, 0, 0, 0, 1})
    end

    test "unwraps IPv4-mapped addresses (::ffff:a.b.c.d) and re-checks as IPv4" do
      # ::ffff:169.254.169.254
      assert SSRF.disallowed?({0, 0, 0, 0, 0, 0xFFFF, 0xA9FE, 0xA9FE})
      # ::ffff:93.184.216.34 (public)
      refute SSRF.disallowed?({0, 0, 0, 0, 0, 0xFFFF, 0x5DB8, 0xD822})
    end

    test "allows plausibly-public IPv6 addresses" do
      # 2606:2800:220:1:248:1893:25c8:1946 (example.com, as of this writing)
      refute SSRF.disallowed?({0x2606, 0x2800, 0x220, 1, 0x248, 0x1893, 0x25C8, 0x1946})
    end
  end

  describe "resolve_public_address/1" do
    test "resolves a real public hostname to an allowed address" do
      assert {:ok, address} = SSRF.resolve_public_address("example.com")
      refute SSRF.disallowed?(address)
    end

    test "rejects a hostname whose only address is private (fails closed)" do
      assert {:error, {:disallowed_address, address}} = SSRF.resolve_public_address("localhost")
      assert SSRF.disallowed?(address)
    end

    test "an unresolvable hostname is an error, not an empty allow" do
      # nonexistent.invalid is guaranteed to never resolve (RFC 2606).
      assert {:error, :unresolvable} = SSRF.resolve_public_address("nonexistent.invalid")
    end
  end
end
