module MailScore
  module Rules
    # No From field, or an empty one.
    class MissingFrom < Rule
      NAME = "FROM_MISSING"
      GROUP = "headers"
      WEIGHT = 2.0
      DESCRIPTION = "No From header"

      def run(message, _envelope)
        Hit.new(name: NAME, weight: WEIGHT) if message.header("from").to_s.empty?
      end
    end
  end
end
