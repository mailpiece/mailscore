module MailScore
  module Rules
    # A HELO that is neither an address nor a dotted host name. Without a
    # client IP there is no session to judge it by.
    class HeloNotFqdn < Rule
      NAME = "HELO_NOT_FULL_DOMAIN"
      GROUP = "hfilter"
      WEIGHT = 2.0
      DESCRIPTION = "Server greeted with an incomplete name"

      FQDN = /\A(?=.{1,253}\z)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z](?:[a-z0-9-]{0,61}[a-z0-9])?\z/i

      def run(_message, envelope)
        if (helo = envelope.helo) && envelope.address && !envelope.trusted? && !HeloBareIp.bare?(helo) && !helo.chomp(".").match?(FQDN)
          Hit.new(name: NAME, weight: WEIGHT, detail: helo)
        end
      end
    end
  end
end
