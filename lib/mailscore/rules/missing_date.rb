module MailScore
  module Rules
    # No Date field, or an empty one.
    class MissingDate < Rule
      NAME = "DATE_MISSING"
      GROUP = "headers"
      WEIGHT = 1.0
      DESCRIPTION = "No Date header"

      def run(message, _envelope)
        Hit.new(name: NAME, weight: WEIGHT) if message.header("date").to_s.empty?
      end
    end
  end
end
