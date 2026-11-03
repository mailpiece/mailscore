require "time"
require "mailscore/classifier/samples"
require "mailscore/classifier/trainer"

module MailScore
  # One fastText model for all mail, trained on the text of the mail Bayes
  # learns. Its input is the words Bayes reads, the Subject's then the
  # decoded text's, without their leading and trailing underscores, joined
  # by spaces and capped at WORD_CAP words and TEXT_CAP bytes, so one long
  # word can't make a sample large. fastText reads a word that starts with
  # its label prefix, __label__, as a class, so mail never carries one in.
  class Classifier
    WORD_CAP = 1000
    TEXT_CAP = 16_384

    @models = {}
    @lock = Mutex.new

    class << self
      def text(message)
        [ *Bayes::Tokens.words(message.subject), *Bayes::Tokens.words(message.content.visible_text) ]
          .filter_map { it.gsub(/\A_+|_+\z/, "").then { it unless it.empty? } }.first(WORD_CAP).then { capped(it) }.join(" ")
      end

      # The words that fit in TEXT_CAP bytes once joined.
      def capped(words)
        bytes = -1
        words.take_while { (bytes += it.bytesize + 1) <= TEXT_CAP }
      end

      # The model at +path+, loaded on a worker's first scan after the fork
      # and again once a training renames a new one over it, which a stat
      # each scan notices. Nil while there is none.
      def model(path)
        version = File.stat(path).then { [ it.ino, it.mtime ] }

        @lock.synchronize do
          @models[path] = [ version, ::FastText.load_model(path) ] unless @models[path]&.first == version
          @models[path].last
        end
      rescue Errno::ENOENT
        nil
      end
    end

    def initialize(config, database)
      @config = config
      @database = database
    end

    # The chance that +message+ is spam, or nil before a model exists, for
    # a message without words, and when the model names neither class.
    def probability(message)
      text = Classifier.text(message)
      model = Classifier.model(@config.fasttext_model) unless text.empty?
      return unless model

      spam, ham = model.predict(text, k: 2).values_at("spam", "ham")
      (spam || (1 - ham if ham))&.clamp(0.0, 1.0)
    end

    # The model in place, its holdout accuracy and the samples it learned,
    # and when the last training ran, swapped or not. Nils before any.
    def stats
      trained_at = @database.execute("SELECT max(trained_at) FROM fasttext_trainings").dig(0, 0)
      accuracy, spam, ham = @database.execute("SELECT accuracy, spam, ham FROM fasttext_trainings WHERE swapped = 1 ORDER BY id DESC LIMIT 1").first

      { "trained_at" => trained_at && Time.at(trained_at).utc.iso8601, "accuracy" => accuracy, "spam_samples" => spam, "ham_samples" => ham }
    end
  end
end
