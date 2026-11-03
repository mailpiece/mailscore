module MailScore
  module Rules
    # FASTTEXT_SPAM or FASTTEXT_HAM by the fastText model's probability, with
    # nothing within DEAD_ZONE of even, and nothing with fastText off or
    # before the first model. The weight is the symbol's full weight times
    # the confidence, (p - 0.5) * 2 for the class named, and the detail is
    # that confidence as a percentage. The weights sit below Bayes': the model
    # learns from the same mail, so the two mostly agree, and fastText's
    # softmax is sure of itself even on little data.
    class Fasttext < Rule
      NAME = "FASTTEXT"
      SYMBOLS = {
        "FASTTEXT_SPAM" => [ 3.0, "Trained model says spam" ],
        "FASTTEXT_HAM" => [ -2.0, "Trained model says not spam" ]
      }.freeze
      DEAD_ZONE = 0.05

      def self.hit(probability)
        return if (probability - 0.5).abs <= DEAD_ZONE

        name, chance = probability > 0.5 ? [ "FASTTEXT_SPAM", probability ] : [ "FASTTEXT_HAM", 1 - probability ]
        confidence = (chance - 0.5) * 2
        Hit.new(name:, weight: (SYMBOLS[name].first * confidence).round(2), detail: format("%.2f%%", confidence * 100))
      end

      def run(message, _envelope)
        MailScore::Classifier.new(@config, @database).probability(message)&.then { Fasttext.hit(it) } if @config.fasttext
      end
    end
  end
end
