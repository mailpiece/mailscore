module MailScore
  module Rules
    # The client has no reverse name. The caller says so with unknown;
    # without a Hostname, or with only the address in brackets, such as
    # [203.0.113.9], mailscore's own lookup found none.
    class HostnameUnknown < Rule
      NAME = "HOSTNAME_UNKNOWN"
      GROUP = "hfilter"
      WEIGHT = 2.5
      DESCRIPTION = "Sending server has no verified host name"

      def run(_message, envelope)
        Hit.new(name: NAME, weight: WEIGHT, detail: envelope.ip) if !envelope.trusted? && unknown?(envelope)
      end

      private
        def unknown?(envelope)
          hostname = envelope.hostname

          if hostname&.casecmp?("unknown") then true
          elsif (lookup = envelope.reverse_dns(resolver(envelope))) then lookup.hostname.nil?
          else hostname.to_s.start_with?("[")
          end
        end
    end
  end
end
