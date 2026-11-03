module MailScore
  module Rules
    # A Date field that cannot be read as a date.
    class InvalidDate < Rule
      NAME = "DATE_INVALID"
      WEIGHT = 1.5
      DESCRIPTION = "Malformed Date header"

      def run(message, _envelope)
        date = message.header("date").to_s
        Hit.new(name: NAME, weight: WEIGHT, detail: date) unless date.empty? || DateInFuture.date(message)
      end
    end
  end
end
