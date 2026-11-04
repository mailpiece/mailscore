module MailScore
  module Rules
    # The message matches a fuzzy hash: the best match per flag fires the
    # flag's symbol. Its weight grows with the hash's count, nearing the
    # flag's weight at its +hits_limit+, and with the similarity, from none
    # at 0.5 to all of it at 1.0. SYMBOLS lists the default flags;
    # +fuzzy_flags+ sets the symbols, weights and hit limits that fire, and
    # +symbols+ lists those, a default symbol with its own description.
    class FuzzyMatch < Rule
      NAME = "FUZZY"
      GROUP = "fuzzy"

      SYMBOLS = {
        "FUZZY_SPAM" => [ 12.0, "Matches known spam" ],
        "FUZZY_PROBABLE_SPAM" => [ 5.0, "Matches probable spam" ],
        "FUZZY_HAM" => [ -2.1, "Matches known good mail" ]
      }.freeze

      def self.symbols(config)
        config.fuzzy_flags.to_h { |flag, setting| [ setting.symbol, [ setting.weight, SYMBOLS.dig(setting.symbol, 1) || "Matches mail flagged #{flag}" ] ] }
      end

      def run(message, _envelope)
        Fuzzy.new(@config, @database).check(message).map do |match|
          flag = @config.fuzzy_flags.fetch(match.flag)
          Hit.new(name: flag.symbol, weight: weight(flag, match), detail: "count #{match.count}, similarity #{match.similarity}")
        end
      end

      private
        def weight(flag, match)
          hits = Math.tanh(Math::E * match.count / flag.hits_limit)
          similarity = ((match.similarity - 0.5) / 0.5).clamp(0.0, 1.0)
          (flag.weight * hits * similarity).round(2)
        end
    end
  end
end
