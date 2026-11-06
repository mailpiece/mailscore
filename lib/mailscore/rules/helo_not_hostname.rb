module MailScore
  module Rules
    # A host name in HELO that is not the client's reverse name, the
    # caller's Hostname or the one mailscore looked up without it.
    # Plenty of honest servers differ, so it weighs little.
    class HeloNotHostname < Rule
      NAME = "HELO_HOSTNAME_MISMATCH"
      GROUP = "hostname"
      WEIGHT = 0.3
      DESCRIPTION = "Server greeting does not match its host name"

      def run(_message, envelope)
        return if envelope.trusted? || !envelope.helo.to_s.chomp(".").match?(HeloNotFqdn::FQDN)

        hostname = envelope.client_hostname(resolver(envelope))
        helo, hostname = [ envelope.helo, hostname ].map { it.to_s.chomp(".").downcase }

        if hostname.match?(HeloNotFqdn::FQDN) && helo != hostname
          Hit.new(name: NAME, weight: WEIGHT, detail: "#{helo} is not #{hostname}")
        end
      end
    end
  end
end
