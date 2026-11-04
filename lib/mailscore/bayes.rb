require "digest"
require "mailscore/bayes/language"
require "mailscore/bayes/tokens"

module MailScore
  # One Bayes classifier for all mail. Each token counts the spam and ham
  # messages it appeared in. A message is known by a digest of its tokens, in
  # order, so a copy with headers added by the caller, or with text that
  # differs only where the tokens do not look, is still the same message.
  #
  # A token's spam probability is Robinson's, pulled toward PRIOR by STRENGTH,
  # and a token leaning less than +bayes_min_prob_strength+ either way says
  # nothing and is dropped; one at exactly even is kept. The rest combine
  # with Fisher's inverse chi-square. It answers only once each class has
  # +bayes_min_learns+ messages.
  #
  # Past +bayes_max_tokens+, +prune+ drops the tokens seen least, which
  # say least, Database::BATCH a statement.
  #
  # Each text part's words are stemmed and its stop words dropped for its
  # language: the one +language_model+ names, or English without one.
  class Bayes
    CLASSES = %w[ spam ham ].freeze
    STRENGTH = 1.0
    PRIOR = 0.5
    MIN_TOKEN_HITS = 2
    CHUNK = 500

    def initialize(config, database)
      @config = config
      @database = database
      @detector = config.language_model ? Language.load(config.language_model) : Language::DEFAULT
    end

    # Learns +message+ as +klass+, or moves it there from the other class.
    # False when it was already learned as +klass+, and nil, learning
    # nothing, when it has fewer than +bayes_min_tokens+ tokens.
    def learn(message, klass)
      other = (CLASSES - [ klass ]).first
      tokens = Tokens.of(message, @detector)
      return if tokens.size < @config.bayes_min_tokens
      digest = Digest::SHA256.hexdigest(tokens.pack("q>*"))

      @database.transaction do
        previous = @database.execute("SELECT class FROM bayes_learned WHERE digest = ?", digest).dig(0, 0)
        next false if previous == klass

        moving = previous == other
        tokens.each_slice(CHUNK) { @database.execute(upsert(klass, other, moving, it.size), *it) }
        @database.execute("INSERT INTO bayes_totals (class, learns) VALUES (?, 1) ON CONFLICT (class) DO UPDATE SET learns = learns + 1", klass)
        @database.execute("UPDATE bayes_totals SET learns = max(learns - 1, 0) WHERE class = ?", other) if moving
        @database.execute("INSERT INTO bayes_learned (digest, class) VALUES (?, ?) ON CONFLICT (digest) DO UPDATE SET class = excluded.class",
          digest, klass)
        Classifier::Samples.new(@config, @database).add(message, klass, digest)
        true
      end
    end

    # With autolearn on, learns a complete scan of an untrusted sender as spam
    # or ham by its score, unless BAYES already called it that class at all,
    # or the greylister held it back for a retry. Returns the class learned,
    # or nil.
    def autolearn(message, envelope, verdict)
      return unless @config.autolearn && verdict.complete && !verdict.greylisted? && !envelope.trusted?

      klass = @config.autolearn_class(verdict.score)
      klass if klass && verdict.hits.none? { it.name == "BAYES_#{klass.upcase}" } && learn(message, klass)
    end

    # The probability that +message+ is spam, or nil before enough learns or
    # without a token seen often enough and leaning far enough, and for a
    # message too short to learn.
    def probability(message)
      tokens = Tokens.of(message, @detector)
      return if tokens.size < @config.bayes_min_tokens

      totals = @database.execute("SELECT class, learns FROM bayes_totals").to_h
      spam_learns, ham_learns = totals.values_at(*CLASSES).map(&:to_i)
      return if [ spam_learns, ham_learns ].min < @config.bayes_min_learns

      probabilities = counts(tokens).filter_map do |spam, ham|
        next if spam + ham < MIN_TOKEN_HITS

        spamminess = spam.fdiv(spam_learns) / (spam.fdiv(spam_learns) + ham.fdiv(ham_learns))
        probability = (STRENGTH * PRIOR + (spam + ham) * spamminess) / (STRENGTH + spam + ham)
        probability unless weak?(probability)
      end

      fisher(probabilities) if probabilities.any?
    end

    def prune
      excess = @database.execute("SELECT count(*) FROM bayes_tokens").dig(0, 0) - @config.bayes_max_tokens
      return unless excess.positive?

      @database.execute("SELECT token FROM bayes_tokens ORDER BY spam + ham LIMIT ?", excess).flatten.each_slice(Database::BATCH) do
        @database.execute("DELETE FROM bayes_tokens WHERE token IN (#{Array.new(it.size, "?").join(", ")})", *it)
      end
    end

    private
      # Adds one to +klass+ for each token and, when moving, takes one from +other+.
      def upsert(klass, other, moving, size)
        values = Array.new(size) { klass == "spam" ? "(?, 1, 0)" : "(?, 0, 1)" }.join(", ")
        moved = ", #{other} = max(#{other} - 1, 0)" if moving
        "INSERT INTO bayes_tokens (token, spam, ham) VALUES #{values} ON CONFLICT (token) DO UPDATE SET #{klass} = #{klass} + 1#{moved}"
      end

      def counts(tokens)
        tokens.each_slice(CHUNK).flat_map do |chunk|
          @database.execute("SELECT spam, ham FROM bayes_tokens WHERE token IN (#{Array.new(chunk.size, "?").join(", ")})", *chunk)
        end
      end

      def weak?(probability)
        strength = @config.bayes_min_prob_strength
        probability.between?(PRIOR - strength, PRIOR + strength) && ![ PRIOR - strength, PRIOR, PRIOR + strength ].include?(probability)
      end

      # 1 when every token leans spam, 0 when every token leans ham.
      def fisher(probabilities)
        degrees = 2 * probabilities.size
        spammy = chi_square_tail(-2 * probabilities.sum { Math.log(it) }, degrees)
        hammy = chi_square_tail(-2 * probabilities.sum { Math.log(1 - it) }, degrees)
        (1 + spammy - hammy) / 2
      end

      # The chance a chi-square with even +degrees+ is at least +x+, summed in
      # logs so that a long message does not underflow.
      def chi_square_tail(x, degrees)
        half = x / 2.0
        return 1.0 if half <= 0

        term = -half
        logs = [ term, *(1...degrees / 2).map { |i| term += Math.log(half / i) } ]
        top = logs.max
        [ Math.exp(top + Math.log(logs.sum { Math.exp(it - top) })), 1.0 ].min
      end
  end
end
