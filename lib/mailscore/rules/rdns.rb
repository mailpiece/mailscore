module MailScore
  module Rules
    # Without a Hostname from the caller, or with only the address in
    # brackets, mailscore looks up the client's reverse DNS itself. No PTR
    # record fires REVERSE_DNS_NONE; a lookup that got no answer in time
    # fires REVERSE_DNS_LOOKUP_FAILED, which weighs nothing, and
    # REVERSE_DNS_NONE too.
    class Rdns < Rule
      NAME = "REVERSE_DNS"

      SYMBOLS = {
        "REVERSE_DNS_NONE" => [ 2.0, "The sending server's IP has no reverse DNS" ],
        "REVERSE_DNS_LOOKUP_FAILED" => [ 0.0, "Reverse DNS lookup failed" ]
      }.freeze

      def run(_message, envelope)
        case envelope.reverse_dns(resolver(envelope))&.status
        when "none" then [ hit("REVERSE_DNS_NONE", envelope.ip) ]
        when "failed" then [ hit("REVERSE_DNS_LOOKUP_FAILED", envelope.ip), hit("REVERSE_DNS_NONE", envelope.ip) ]
        else []
        end
      end

      private
        def hit(name, detail)
          Hit.new(name:, weight: SYMBOLS.fetch(name).first, detail:)
        end
    end
  end
end
