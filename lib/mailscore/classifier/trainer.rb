require "fasttext"

module MailScore
  class Classifier
    # Trains a new model on the samples and puts it in place of the current
    # one unless it does worse. Every HOLDOUT-th sample by id is held out of
    # every training, so both models are judged on mail neither learned from.
    # The model is written beside +fasttext_model+ and renamed over it, so a
    # worker never loads half a file. Each training is recorded, with its
    # accuracy, the current model's and its sample counts.
    class Trainer
      HOLDOUT = 5
      OPTIONS = { word_ngrams: 2, bucket: 100_000, dim: 16, min_count: 2, epoch: 25, lr: 0.5, thread: 1, verbose: 0, label_prefix: "__label__" }.freeze

      Training = Data.define(:accuracy, :previous_accuracy, :spam, :ham, :swapped)

      def initialize(config, database)
        @config = config
        @database = database
      end

      # When each class has +fasttext_min_samples+ and the last training is
      # +fasttext_train_every+ old, or there was none.
      def due?(now: Time.now)
        last = @database.execute("SELECT max(trained_at) FROM fasttext_trainings").dig(0, 0)
        enough? && (last.nil? || last <= now.to_i - @config.fasttext_train_every)
      end

      # The Training, or nil before enough samples of each class to train on.
      def train(now: Time.now)
        return unless enough?

        holdout, training = @database.execute("SELECT id, class, text FROM fasttext_samples").partition { |id, *| (id % HOLDOUT).zero? }
        return unless training.map { it[1] }.uniq.size == Bayes::CLASSES.size

        model = ::FastText::Classifier.new(**OPTIONS).tap { it.fit(training.map(&:last), training.map { it[1] }) }

        accuracy = accuracy(model, holdout)
        previous_accuracy = current&.then { accuracy(it, holdout) }
        swapped = previous_accuracy.nil? || accuracy >= previous_accuracy
        save(model) if swapped

        counts = training.map { it[1] }.tally
        Training.new(accuracy:, previous_accuracy:, spam: counts.fetch("spam", 0), ham: counts.fetch("ham", 0), swapped:).tap do |done|
          @database.execute("INSERT INTO fasttext_trainings (trained_at, spam, ham, accuracy, previous_accuracy, swapped) VALUES (?, ?, ?, ?, ?, ?)",
            now.to_i, done.spam, done.ham, done.accuracy, done.previous_accuracy, done.swapped ? 1 : 0)
        end
      end

      private
        def enough?
          Samples.new(@config, @database).counts.values.min >= @config.fasttext_min_samples
        end

        def current
          ::FastText.load_model(@config.fasttext_model) if File.exist?(@config.fasttext_model)
        end

        # The share of +samples+ whose class +model+ guesses.
        def accuracy(model, samples)
          return 0.0 if samples.empty?
          samples.count { |_, klass, text| model.predict(text).keys.first == klass }.fdiv(samples.size)
        end

        def save(model)
          temporary = "#{@config.fasttext_model}.#{Process.pid}.tmp"
          model.save_model(temporary)
          File.rename(temporary, @config.fasttext_model)
        ensure
          File.delete(temporary) if temporary && File.exist?(temporary)
        end
    end
  end
end
