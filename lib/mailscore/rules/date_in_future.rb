require "time"

module MailScore
  module Rules
    # A Date further ahead of the clock than +date_future_margin+ seconds.
    class DateInFuture < Rule
      NAME = "DATE_IN_FUTURE"
      WEIGHT = 4.0
      DESCRIPTION = "Date header in the future"

      def self.date(message)
        message.header("date")&.then { Time.rfc2822(it) }
      rescue ArgumentError
        nil
      end

      def initialize(config, database, now: Time.now)
        super(config, database)
        @now = now
      end

      def run(message, _envelope)
        if (date = DateInFuture.date(message)) && date - @now > @config.date_future_margin
          Hit.new(name: NAME, weight: WEIGHT, detail: "#{((date - @now) / 3600).floor} hours ahead")
        end
      end
    end
  end
end
