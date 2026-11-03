require "ipaddr"

module MailScore
  module Rules
    # A client that greets with an address, bare, as a literal or spelled
    # with dashes, has no name it will stand behind. A private or reserved
    # address is HeloBadIp's instead.
    class HeloBareIp < Rule
      NAME = "HELO_IP_ADDRESS"
      WEIGHT = 3.0
      DESCRIPTION = "Server greeted with an IP address"

      # Four numbers joined by dots, dashes or an x, such as 1-2-3-4.
      DOTTED = /\A\d+[x.-]\d+[x.-]\d+[x.-]\d+\z/i

      def run(_message, envelope)
        helo = envelope.helo
        Hit.new(name: NAME, weight: WEIGHT, detail: helo) if !envelope.trusted? && HeloBareIp.bare?(helo) && !HeloBadIp.bad?(helo)
      end

      def self.bare?(helo)
        helo && (address(helo) || helo.delete("[]").match?(DOTTED))
      end

      # The address a HELO names, without brackets or an IPv6: tag, or nil.
      def self.address(helo)
        IPAddr.new(helo.delete("[]").delete_prefix("IPv6:")).native if helo
      rescue IPAddr::Error
        nil
      end
    end
  end
end
