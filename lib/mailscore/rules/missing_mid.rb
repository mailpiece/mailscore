module MailScore
  module Rules
    # No Message-ID field. An empty one is MESSAGE_ID_INVALID's.
    class MissingMid < Rule
      NAME = "MESSAGE_ID_MISSING"
      GROUP = "headers"
      WEIGHT = 2.5
      DESCRIPTION = "No Message-ID header"

      def run(message, _envelope)
        Hit.new(name: NAME, weight: WEIGHT) if message.header_values("message-id").empty?
      end
    end
  end
end
