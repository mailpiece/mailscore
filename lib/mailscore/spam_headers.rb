module MailScore
  # The X-Spam- fields a caller adds to the message it hands on, as
  # [name, value] pairs in order, for a Verdict under +thresholds+.
  class SpamHeaders
    STARS_CAP = 50
    # The actions that mark or stop a message, the lowest on sets required=.
    VISIBLE = %w[ add_header rewrite_subject reject ].freeze

    def initialize(verdict, thresholds)
      @verdict = verdict
      @thresholds = thresholds
    end

    # A value never carries a CR or an LF, so it cannot start a field of its own.
    def to_a
      fields.map { |name, value| [ name, value.delete("\r\n") ] }
    end

    private
      def fields
        [ [ "X-Spam-Flag", flagged? ? "YES" : "NO" ],
          [ "X-Spam-Score", score ],
          ([ "X-Spam-Level", level ] unless level.empty?),
          [ "X-Spam-Status", status ],
          [ "X-Spam-Action", @verdict.action.tr("_", " ") ] ].compact
      end

      def flagged?
        @verdict.action != "no_action"
      end

      def score
        decimal(@verdict.score)
      end

      def level
        "*" * @verdict.score.floor.clamp(0, STARS_CAP)
      end

      def status
        [ flagged? ? "Yes," : "No,", "score=#{score}", required&.then { "required=#{decimal(it)}" }, "tests=#{tests}" ].compact.join(" ")
      end

      def required
        @thresholds.values_at(*VISIBLE).compact.first
      end

      def tests
        @verdict.hits.empty? ? "none" : @verdict.hits.map(&:name).join(",")
      end

      # One decimal, never -0.0.
      def decimal(number)
        format("%.1f", number.round(1) + 0.0)
      end
  end
end
