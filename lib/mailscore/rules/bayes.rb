module MailScore
  module Rules
    # BAYES_SPAM or BAYES_HAM by the classifier's probability, with nothing
    # within DEAD_ZONE of even. The weight is the symbol's full weight times
    # the eighth power of the confidence, (p - 0.5) * 2 for the class named,
    # so only a near-certain call weighs much. The detail is that confidence
    # as a percentage.
    class Bayes < Rule
      NAME = "BAYES"
      SYMBOLS = {
        "BAYES_SPAM" => [ 5.1, "The Bayes classifier says spam" ],
        "BAYES_HAM" => [ -3.0, "The Bayes classifier says ham" ]
      }.freeze
      DEAD_ZONE = 0.05

      def self.hit(probability)
        return if (probability - 0.5).abs <= DEAD_ZONE

        name, chance = probability > 0.5 ? [ "BAYES_SPAM", probability ] : [ "BAYES_HAM", 1 - probability ]
        confidence = (chance - 0.5) * 2
        Hit.new(name:, weight: (SYMBOLS[name].first * confidence**8).round(2), detail: format("%.2f%%", confidence * 100))
      end

      def run(message, _envelope)
        MailScore::Bayes.new(@config, @database).probability(message)&.then { Bayes.hit(it) }
      end
    end
  end
end
