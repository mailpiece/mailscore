module MailScore
  module Rules
    # A sender domain spelled with look-alike letters from another script.
    class FromHomograph < Rule
      NAME = "FROM_LOOKALIKE_DOMAIN"
      GROUP = "headers"
      WEIGHT = 5.0
      DESCRIPTION = "Sender domain uses look-alike letters"

      def run(message, envelope)
        domains = [ envelope.from, *message.from_addresses ].filter_map { it.to_s.rpartition("@").last.downcase.then { it unless it.empty? } }

        if (domain = domains.find { Content::Url.homograph?(it) })
          Hit.new(name: NAME, weight: WEIGHT, detail: domain)
        end
      end
    end
  end
end
