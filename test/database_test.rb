require "test_helper"

class MailScore::DatabaseTest < MailScore::TestCase
  def setup
    @database = MailScore::Database.new(File.join(Dir.mktmpdir, "mailscore.sqlite3"), busy_timeout: 5)
    @database.prepare
  end

  def teardown
    @database.close
  end

  def test_the_database_runs_in_wal_with_normal_sync
    assert_equal [ [ "wal" ] ], @database.execute("PRAGMA journal_mode")
    assert_equal [ [ 1 ] ], @database.execute("PRAGMA synchronous")
  end

  def test_rows_past_their_expiry_are_deleted
    @database.execute("CREATE TABLE entries (key TEXT, expires_at INTEGER)")
    @database.execute("INSERT INTO entries VALUES ('old', 100), ('new', 300)")

    @database.expire(now: Time.at(200), tables: [ "entries" ])

    assert_equal [ [ "new" ] ], @database.execute("SELECT key FROM entries")
  end

  def test_expiry_deletes_a_batch_a_statement
    @database.execute("CREATE TABLE entries (key TEXT, flag TEXT, expires_at INTEGER, PRIMARY KEY (key, flag)) WITHOUT ROWID")
    @database.execute("WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 2500) INSERT INTO entries SELECT i, 'f', 100 FROM n")
    deleted = []
    @database.define_singleton_method(:execute) { |sql, *params| super(sql, *params).tap { deleted << it.size if sql.start_with?("DELETE") } }

    @database.expire(now: Time.at(200), tables: [ "entries" ])

    assert_equal [ 1000, 1000, 500 ], deleted
    assert_equal [ [ 0 ] ], @database.execute("SELECT count(*) FROM entries")
  end

  def test_a_transaction_commits_together_or_not_at_all
    @database.execute("CREATE TABLE entries (key TEXT)")
    @database.transaction { 2.times { @database.execute("INSERT INTO entries VALUES ('kept')") } }
    assert_raises(RuntimeError) do
      @database.transaction do
        @database.execute("INSERT INTO entries VALUES ('lost')")
        raise "stop"
      end
    end

    assert_equal [ [ "kept" ], [ "kept" ] ], @database.execute("SELECT key FROM entries")
  end

  def test_a_transaction_answers_its_block
    @database.execute("CREATE TABLE entries (key TEXT)")

    assert_equal [ [ "new" ] ], @database.transaction { @database.execute("INSERT INTO entries VALUES ('new') RETURNING key") }
    assert_equal false, @database.transaction { next false }
  end

  def test_counters_start_at_zero_and_add_up
    stats = MailScore::Stats.new(@database)
    2.times { stats.increment("unauthorized") }

    assert_equal 2, stats.to_h["unauthorized"]
    assert_equal [ 0 ], stats.to_h.except("unauthorized").values.uniq
  end

  def test_counters_restart_with_the_server
    MailScore::Stats.new(@database).increment("too_large")
    @database.prepare

    assert_equal 0, MailScore::Stats.new(@database).to_h["too_large"]
  end

  def test_dns_lists_offline_are_forgotten_with_the_server
    @database.execute("INSERT INTO offline_dns_lists (zone) VALUES ('bl.example')")
    @database.prepare

    assert_empty @database.execute("SELECT zone FROM offline_dns_lists")
  end

  def test_a_reputation_table_with_other_columns_is_replaced_and_a_current_one_kept
    path = File.join(Dir.mktmpdir, "old.sqlite3")
    SQLite3::Database.new(path) do |db|
      db.execute("CREATE TABLE reputation (selector TEXT, value TEXT, ham REAL, junk REAL, spam REAL, updated_at INTEGER, expires_at INTEGER)")
      db.execute("INSERT INTO reputation VALUES ('ip', '203.0.113.9', 1, 0, 0, 0, 0)")
    end
    database = MailScore::Database.new(path, busy_timeout: 5).tap(&:prepare)
    database.execute("INSERT INTO reputation VALUES ('ip', '203.0.113.9', 4.5, 1, 0, 0)")
    database.prepare

    assert_equal %w[ selector value score count updated_at expires_at ], database.execute("SELECT name FROM pragma_table_info('reputation')").flatten
    assert_equal [ [ 4.5 ] ], database.execute("SELECT score FROM reputation")
  ensure
    database&.close
  end
end
