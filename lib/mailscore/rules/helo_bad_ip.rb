require "ipaddr"

module MailScore
  module Rules
    # A HELO address no client on the internet can have: private, loopback,
    # link-local, a documentation range, or an IPv4 broadcast address.
    class HeloBadIp < Rule
      NAME = "HELO_PRIVATE_IP"
      GROUP = "hostname"
      WEIGHT = 4.5
      DESCRIPTION = "Server greeted with a private address"

      NETWORKS = %w[
        0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12 192.0.0.0/24 192.0.2.0/24
        192.88.99.0/24 192.168.0.0/16 198.51.100.0/24 203.0.113.0/24 ::1/128 2001:db8::/32 fc00::/7 fe80::/10 fec0::/10
      ].map { IPAddr.new(it) }.freeze

      def run(_message, envelope)
        Hit.new(name: NAME, weight: WEIGHT, detail: envelope.helo) if !envelope.trusted? && HeloBadIp.bad?(envelope.helo)
      end

      def self.bad?(helo)
        if (address = HeloBareIp.address(helo))
          NETWORKS.any? { it.include?(address) } || (address.ipv4? && (address.to_i & 0xff) == 0xff)
        end
      end
    end
  end
end
