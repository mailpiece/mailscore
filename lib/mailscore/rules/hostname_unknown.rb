module MailScore
  module Rules
    # The client has no reverse name. The caller says so with unknown;
    # without a Hostname, or with only the address in brackets, such as
    # [203.0.113.9], mailscore's own lookup found none. A failed lookup,
    # the caller's or mailscore's, says nothing either way. It weighs
    # nothing, so the verdict shows it without scoring it.
    class HostnameUnknown < Rule
      NAME = "HOSTNAME_UNKNOWN"
      GROUP = "hfilter"
      WEIGHT = 0.0
      DESCRIPTION = "Sending server has no verified host name"

      def run(_message, envelope)
        Hit.new(name: NAME, weight: WEIGHT, detail: envelope.ip) if !envelope.trusted? && unknown?(envelope)
      end

      private
        def unknown?(envelope)
          hostname = envelope.hostname

          if (lookup = envelope.reverse_dns(resolver(envelope))) then lookup.status == "none"
          elsif hostname&.casecmp?("unknown") then true
          else hostname.to_s.start_with?("[")
          end
        end
    end
  end
end
