defmodule MCP.OAuth.CIMD.SSRF do
  @moduledoc """
  DNS resolution + address allow-listing for outbound CIMD fetches.

  Resolve-then-pin is the whole point: `resolve_public_address/1` is the ONLY
  place DNS gets resolved. Callers must connect to the returned address
  directly (not re-resolve the hostname at connect time), or a second DNS
  lookup between this check and the TCP connect lets an attacker swap in a
  private address after validation (DNS rebinding / TOCTOU).

  Fails closed: any resolution error, or any single disallowed address among
  multiple A/AAAA records, is rejected — a host is not "safe" just because
  one of its addresses is public.
  """

  import Bitwise

  @type reason :: :unresolvable | {:disallowed_address, :inet.ip_address()}

  @spec resolve_public_address(String.t()) :: {:ok, :inet.ip_address()} | {:error, reason()}
  def resolve_public_address(host) when is_binary(host) do
    charlist = String.to_charlist(host)

    addresses =
      [:inet, :inet6]
      |> Enum.flat_map(fn family ->
        case :inet.getaddrs(charlist, family) do
          {:ok, addrs} -> addrs
          {:error, _reason} -> []
        end
      end)
      |> Enum.uniq()

    case addresses do
      [] ->
        {:error, :unresolvable}

      addrs ->
        case Enum.find(addrs, &disallowed?/1) do
          nil -> {:ok, hd(addrs)}
          bad_address -> {:error, {:disallowed_address, bad_address}}
        end
    end
  end

  @doc """
  True for loopback, RFC1918/CGNAT private ranges, link-local (including the
  169.254.169.254 / fd00:ec2::254 cloud instance-metadata addresses),
  multicast, and reserved/documentation ranges. False only for addresses left
  over, i.e. plausibly-public unicast space.
  """
  @spec disallowed?(:inet.ip_address()) :: boolean()
  # IPv4-mapped IPv6 (::ffff:a.b.c.d) — unwrap and re-check as IPv4, or a
  # server reachable only over that form bypasses every IPv4 rule below.
  def disallowed?({0, 0, 0, 0, 0, 0xFFFF, hi, lo}) do
    disallowed?({div(hi, 256), rem(hi, 256), div(lo, 256), rem(lo, 256)})
  end

  def disallowed?({127, _, _, _}), do: true
  def disallowed?({10, _, _, _}), do: true
  def disallowed?({172, b, _, _}) when b in 16..31, do: true
  def disallowed?({192, 168, _, _}), do: true
  # 169.254.0.0/16: link-local, also where AWS/GCP/Azure serve instance metadata.
  def disallowed?({169, 254, _, _}), do: true
  # 100.64.0.0/10: CGNAT.
  def disallowed?({100, b, _, _}) when b in 64..127, do: true
  def disallowed?({0, _, _, _}), do: true
  def disallowed?({192, 0, 0, _}), do: true
  def disallowed?({192, 0, 2, _}), do: true
  def disallowed?({198, b, _, _}) when b in 18..19, do: true
  def disallowed?({198, 51, 100, _}), do: true
  def disallowed?({203, 0, 113, _}), do: true
  # 224.0.0.0/4 multicast + 240.0.0.0/4 reserved + 255.255.255.255 broadcast.
  def disallowed?({a, _, _, _}) when is_integer(a) and a >= 224, do: true

  def disallowed?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  def disallowed?({0, 0, 0, 0, 0, 0, 0, 0}), do: true
  # fc00::/7 unique local (includes fd00:ec2::254, the AWS IPv6 metadata address).
  def disallowed?({h, _, _, _, _, _, _, _}) when band(h, 0xFE00) == 0xFC00, do: true
  # fe80::/10 link-local.
  def disallowed?({h, _, _, _, _, _, _, _}) when band(h, 0xFFC0) == 0xFE80, do: true
  # ff00::/8 multicast.
  def disallowed?({h, _, _, _, _, _, _, _}) when band(h, 0xFF00) == 0xFF00, do: true

  def disallowed?(_address), do: false
end
