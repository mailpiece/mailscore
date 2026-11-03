module MailScore
  class Classifier
    # The text of each message learned, with fastText on, to train the model
    # on. A sample is keyed by the +digest+ Bayes learned its message by, so
    # relearning the message as the other class moves it. Each class keeps
    # its newest +fasttext_max_samples+, and a sample expires
    # +fasttext_sample_expiry+ seconds after it was learned. Bayes adds within
    # its learn's transaction.
    class Samples
      def initialize(config, database)
        @config = config
        @database = database
      end

      def add(message, klass, digest, now: Time.now)
        return unless @config.fasttext

        text = Classifier.text(message)
        return if text.empty?

        @database.execute(<<~SQL, digest, klass, text, now.to_i, now.to_i + @config.fasttext_sample_expiry)
          INSERT INTO fasttext_samples (digest, class, text, learned_at, expires_at) VALUES (?, ?, ?, ?, ?)
          ON CONFLICT (digest) DO UPDATE SET class = excluded.class, text = excluded.text, learned_at = excluded.learned_at, expires_at = excluded.expires_at
        SQL
        @database.execute(<<~SQL, klass, klass, @config.fasttext_max_samples)
          DELETE FROM fasttext_samples WHERE class = ? AND id <= (SELECT id FROM fasttext_samples WHERE class = ? ORDER BY id DESC LIMIT 1 OFFSET ?)
        SQL
      end

      # Samples kept per class, as { "spam" => n, "ham" => n }.
      def counts
        Bayes::CLASSES.to_h { [ it, 0 ] }.merge(@database.execute("SELECT class, count(*) FROM fasttext_samples GROUP BY class").to_h)
      end
    end
  end
end
