require "fasttext"

module MailScore
  class Bayes
    # Names a text's language with a fastText language identification model,
    # such as lid.176.ftz, loaded once per path in each process. The most
    # likely language wins, and English stands in when the model has no
    # answer, or for every text with DEFAULT, which has no model. A text
    # without words has no language.
    class Language
      FALLBACK = "en"
      WORD_BYTES = 256

      @models = {}
      @mutex = Mutex.new

      def self.load(path)
        @mutex.synchronize { @models[path] ||= new(FastText.load_model(path)) }
      end

      def initialize(model)
        @model = model
      end

      DEFAULT = new(nil).freeze

      # The model reads the words as written, without those over WORD_BYTES.
      def detect(text)
        words = text.scan(Tokens::WORD).select { it.bytesize <= WORD_BYTES }
        @model&.predict(words.join(" "))&.keys&.first || FALLBACK if words.any?
      end
    end
  end
end
