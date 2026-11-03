require "monitor"
require "sqlite3"

module MailScore
  # One SQLite file shared by every worker process. Each process opens its own
  # connection on first use, after the fork, and its threads take turns on it.
  # A row in a table listed in +EXPIRING_TABLES+ is deleted once its
  # +expires_at+ (Unix seconds) passes.
  class Database
    SCHEMA = <<~SQL
      CREATE TABLE IF NOT EXISTS counters (name TEXT PRIMARY KEY, value INTEGER NOT NULL) WITHOUT ROWID;
      CREATE TABLE IF NOT EXISTS greylist (key TEXT PRIMARY KEY, first_seen INTEGER NOT NULL, expires_at INTEGER NOT NULL) WITHOUT ROWID;
      CREATE INDEX IF NOT EXISTS greylist_expires_at ON greylist (expires_at);
      CREATE TABLE IF NOT EXISTS reputation (selector TEXT NOT NULL, value TEXT NOT NULL, score REAL NOT NULL, count INTEGER NOT NULL,
        updated_at INTEGER NOT NULL, expires_at INTEGER NOT NULL, PRIMARY KEY (selector, value)) WITHOUT ROWID;
      CREATE INDEX IF NOT EXISTS reputation_expires_at ON reputation (expires_at);
      CREATE TABLE IF NOT EXISTS fuzzy_hashes (hash TEXT NOT NULL, flag TEXT NOT NULL, count INTEGER NOT NULL, last_seen INTEGER NOT NULL,
        expires_at INTEGER NOT NULL, PRIMARY KEY (hash, flag)) WITHOUT ROWID;
      CREATE INDEX IF NOT EXISTS fuzzy_hashes_expires_at ON fuzzy_hashes (expires_at);
      CREATE TABLE IF NOT EXISTS fuzzy_shingles (hash TEXT NOT NULL, flag TEXT NOT NULL, shingle INTEGER NOT NULL, expires_at INTEGER NOT NULL,
        PRIMARY KEY (hash, flag, shingle)) WITHOUT ROWID;
      CREATE INDEX IF NOT EXISTS fuzzy_shingles_shingle ON fuzzy_shingles (shingle);
      CREATE INDEX IF NOT EXISTS fuzzy_shingles_expires_at ON fuzzy_shingles (expires_at);
      CREATE TABLE IF NOT EXISTS bayes_tokens (token INTEGER PRIMARY KEY, spam INTEGER NOT NULL, ham INTEGER NOT NULL);
      CREATE TABLE IF NOT EXISTS bayes_totals (class TEXT PRIMARY KEY, learns INTEGER NOT NULL) WITHOUT ROWID;
      CREATE TABLE IF NOT EXISTS bayes_learned (digest TEXT PRIMARY KEY, class TEXT NOT NULL) WITHOUT ROWID;
      CREATE TABLE IF NOT EXISTS fasttext_samples (id INTEGER PRIMARY KEY, digest TEXT NOT NULL UNIQUE, class TEXT NOT NULL, text TEXT NOT NULL,
        learned_at INTEGER NOT NULL, expires_at INTEGER NOT NULL);
      CREATE INDEX IF NOT EXISTS fasttext_samples_class ON fasttext_samples (class, id);
      CREATE INDEX IF NOT EXISTS fasttext_samples_expires_at ON fasttext_samples (expires_at);
      CREATE TABLE IF NOT EXISTS fasttext_trainings (id INTEGER PRIMARY KEY, trained_at INTEGER NOT NULL, spam INTEGER NOT NULL, ham INTEGER NOT NULL,
        accuracy REAL NOT NULL, previous_accuracy REAL, swapped INTEGER NOT NULL);
    SQL

    # A table whose columns no longer match is dropped before the schema
    # recreates it, losing what it held.
    COLUMNS = { "reputation" => %w[ selector value score count updated_at expires_at ] }.freeze

    EXPIRING_TABLES = %w[ greylist reputation fuzzy_hashes fuzzy_shingles fasttext_samples ].freeze
    BATCH = 1000

    def initialize(path, busy_timeout:)
      @path = path
      @busy_timeout = busy_timeout
      @mutex = Monitor.new
    end

    # Creates the schema and zeroes the counters. Run once at boot, before the fork.
    def prepare
      @mutex.synchronize do
        drop_outdated_tables
        connection.execute_batch(SCHEMA)
      end
      execute("DELETE FROM counters")
    end

    def execute(sql, *params)
      @mutex.synchronize { connection.execute(sql, params) }
    end

    # Runs the block's statements in one write transaction. The lock is
    # reentrant, so +execute+ works inside the block.
    def transaction
      @mutex.synchronize { connection.transaction(:immediate) { yield } }
    end

    # Deletes BATCH rows a statement, so a writer never waits long on one.
    def expire(now: Time.now, tables: EXPIRING_TABLES)
      tables.each do |table|
        keys = primary_key(table)
        sql = "DELETE FROM \"#{table}\" WHERE (#{keys}) IN (SELECT #{keys} FROM \"#{table}\" WHERE expires_at <= ? LIMIT #{BATCH}) RETURNING 1"
        nil while execute(sql, now.to_i).size == BATCH
      end
    end

    def close
      @mutex.synchronize do
        @connection&.close
        @connection = nil
      end
    end

    private
      def drop_outdated_tables
        COLUMNS.each do |table, columns|
          existing = connection.execute("SELECT name FROM pragma_table_info(?)", [ table ]).flatten
          connection.execute("DROP TABLE \"#{table}\"") if existing.any? && existing != columns
        end
      end

      # The table's key columns, or its rowid without one.
      def primary_key(table)
        execute("SELECT name FROM pragma_table_info(?) WHERE pk > 0 ORDER BY pk", table).flatten.map { "\"#{it}\"" }.join(", ").then { it.empty? ? "rowid" : it }
      end

      def connection
        @connection ||= SQLite3::Database.new(@path).tap do |connection|
          connection.busy_handler_timeout = (@busy_timeout * 1000).round
          connection.execute("PRAGMA journal_mode = WAL")
          connection.execute("PRAGMA synchronous = NORMAL")
        end
      end
  end
end
