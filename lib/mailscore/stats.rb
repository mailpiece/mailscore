module MailScore
  # Counters since start, shared by the worker processes through the database.
  # Only ever counts: never content, never addresses. A count anyone can
  # raise, without a token, is kept in memory until +flush+ writes it, so
  # it never costs a write of its own.
  class Stats
    COUNTERS = %w[ unauthorized too_large scans_no_action scans_add_header scans_rewrite_subject scans_soft_reject scans_reject
      budget_overruns rule_errors scan_errors fuzzy_adds fuzzy_deletes fuzzy_matches
      learns_spam learns_ham autolearns_spam autolearns_ham trap_hits ].freeze

    def initialize(database)
      @database = database
      @pending = Hash.new(0)
      @lock = Mutex.new
    end

    def count_in_memory(name)
      raise ArgumentError, "unknown counter: #{name}" unless COUNTERS.include?(name)
      @lock.synchronize { @pending[name] += 1 }
    end

    def flush
      @lock.synchronize do
        @pending.each { |name, value| add(name, value) }
        @pending.clear
      end
    end

    def increment(name)
      raise ArgumentError, "unknown counter: #{name}" unless COUNTERS.include?(name)
      add(name, 1)
    end

    def to_h
      flush
      COUNTERS.to_h { |name| [ name, 0 ] }.merge(@database.execute("SELECT name, value FROM counters").to_h)
    end

    private
      def add(name, value)
        @database.execute("INSERT INTO counters (name, value) VALUES (?, ?) ON CONFLICT (name) DO UPDATE SET value = value + excluded.value", name, value)
      end
  end
end
