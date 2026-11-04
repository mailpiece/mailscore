module MailScore
  module Rules
    # No To field. An empty one, such as mail sent to Bcc alone, is fine.
    class MissingTo < Rule
      NAME = "TO_MISSING"
      GROUP = "headers"
      WEIGHT = 2.0
      DESCRIPTION = "No To header"

      def run(message, _envelope)
        Hit.new(name: NAME, weight: WEIGHT) if message.header_values("to").empty?
      end
    end
  end
end
