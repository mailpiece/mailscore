module MailScore
  module Rules
    # Without a Hostname from the caller, or with only the address in
    # brackets, mailscore looks up the client's reverse DNS itself. No PTR
    # record fires REVERSE_DNS_NONE. A lookup that failed, mailscore's or the
    # caller's, says nothing either way: it fires only
    # REVERSE_DNS_LOOKUP_FAILED, which weighs nothing, so the cause shows.
    class Rdns < Rule
      NAME = "REVERSE_DNS"
      GROUP = "hfilter"

      SYMBOLS = {
        "REVERSE_DNS_NONE" => [ 2.0, "No reverse DNS for the sending server" ],
        "REVERSE_DNS_LOOKUP_FAILED" => [ 0.0, "Reverse DNS lookup failed" ]
      }.freeze

      def run(_message, envelope)
        case envelope.reverse_dns(resolver(envelope))&.status
        when "none" then [ hit("REVERSE_DNS_NONE", envelope.ip) ]
        when "failed" then [ hit("REVERSE_DNS_LOOKUP_FAILED", envelope.ip) ]
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
