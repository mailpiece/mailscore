module MailScore
  # Trap addresses, which only spammers write to. Mail from an untrusted
  # sender to a trap, when the trap is its only recipient or
  # +trap_allow_multiple_rcpts+ is on, fires SENT_TO_TRAP through Rules::Trap. After
  # the verdict it adds its fuzzy hashes under +trap_fuzzy_flag+,
  # +trap_fuzzy_weight+ to the count, and is learned as spam with +trap_learn_spam+,
  # each when switched on. Mail to a trap and others is left alone.
  class Trap
    def initialize(config, database)
      @config = config
      @database = database
    end

    def trapped?(envelope)
      recipients = envelope.recipients.map(&:downcase).uniq
      !envelope.trusted? && (recipients.one? || @config.trap_allow_multiple_rcpts) && recipients.any? { @config.trap_addresses.include?(it) }
    end

    # Counts the hit and acts on it. A message already learned as spam is fine.
    def spring(message, envelope)
      return unless trapped?(envelope)

      Stats.new(@database).increment("trap_hits")

      Fuzzy.new(@config, @database).add(message, @config.trap_fuzzy_flag, count: @config.trap_fuzzy_weight) if @config.trap_fuzzy_flag
      Bayes.new(@config, @database).learn(message, "spam") if @config.trap_learn_spam
    end
  end
end
