module MailScore
  module Rules
    # A Date further behind the clock than +date_past_margin+ seconds.
    class DateInPast < Rule
      NAME = "DATE_TOO_OLD"
      GROUP = "headers"
      WEIGHT = 1.0
      DESCRIPTION = "Date header far in the past"

      def initialize(config, database, now: Time.now)
        super(config, database)
        @now = now
      end

      def run(message, _envelope)
        if (date = DateInFuture.date(message)) && @now - date > @config.date_past_margin
          Hit.new(name: NAME, weight: WEIGHT, detail: "#{((@now - date) / 3600).floor} hours old")
        end
      end
    end
  end
end
