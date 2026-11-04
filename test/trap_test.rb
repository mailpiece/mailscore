require "test_helper"
require "rack/mock_request"
require_relative "fuzzy_test"

class MailScore::TrapTest < MailScore::TestCase
  OFFER = MailScore::FuzzyTest::OFFER
  UNGREYLISTED = SETTINGS["actions"].merge("greylist" => false).freeze
  TRAPPING = { "trap_addresses" => [ "Trap@Example.net" ], "trap_fuzzy_flag" => "spam", "trap_learn_spam" => true }.freeze

  def setup
    @path = File.join(Dir.mktmpdir, "mailscore.sqlite3")
    @database = MailScore::Database.new(@path, busy_timeout: 5).tap(&:prepare)
  end

  def teardown
    @database.close
  end

  def test_mail_to_a_trap_fires_trap_without_naming_it
    app = app(TRAPPING)

    assert_equal [ { "name" => "SENT_TO_TRAP", "weight" => 10.0, "description" => "Sent to a trap address" } ], symbols(app, rcpt: "<trap@example.net>")
    assert_empty symbols(app, rcpt: "<bob@example.net>")
  end

  def test_mail_to_a_trap_adds_its_fuzzy_hashes_ten_times_and_is_learned_as_spam
    check(app(TRAPPING), rcpt: "<Trap@example.net>")

    assert_equal [ [ "spam", 10 ] ], @database.execute("SELECT flag, count FROM fuzzy_hashes")
    assert_equal [ [ "spam" ] ], @database.execute("SELECT class FROM bayes_learned")
  end

  def test_the_fuzzy_weight_can_be_set
    check(app(TRAPPING.merge("trap_fuzzy_weight" => 3)), rcpt: "<trap@example.net>")

    assert_equal [ [ "spam", 3 ] ], @database.execute("SELECT flag, count FROM fuzzy_hashes")
  end

  def test_a_trap_beside_other_recipients_is_left_alone
    app = app(TRAPPING)

    assert_empty symbols(app, rcpt: "<bob@example.net>, <trap@example.net>")
    assert_empty @database.execute("SELECT * FROM fuzzy_hashes")
    assert_empty @database.execute("SELECT * FROM bayes_learned")
    assert_equal 0, stats(app)["trap_hits"]

    check(app, rcpt: "<trap@example.net>, <Trap@Example.net>")
    assert_equal [ [ "spam", 10 ] ], @database.execute("SELECT flag, count FROM fuzzy_hashes")
  end

  def test_a_trap_beside_other_recipients_acts_when_allowed
    app = app(TRAPPING.merge("trap_allow_multiple_rcpts" => true))

    assert_equal [ { "name" => "SENT_TO_TRAP", "weight" => 10.0, "description" => "Sent to a trap address" } ], symbols(app, rcpt: "<bob@example.net>, <trap@example.net>")
    assert_equal [ [ "spam", 10 ] ], @database.execute("SELECT flag, count FROM fuzzy_hashes")
    assert_equal [ [ "spam" ] ], @database.execute("SELECT class FROM bayes_learned")
    assert_equal 1, stats(app)["trap_hits"]
  end

  def test_each_switch_is_separate_and_off_by_default
    check(app("trap_addresses" => [ "trap@example.net" ]), rcpt: "<trap@example.net>")
    assert_empty @database.execute("SELECT * FROM fuzzy_hashes")
    assert_empty @database.execute("SELECT * FROM bayes_learned")

    check(app("trap_addresses" => [ "trap@example.net" ], "trap_fuzzy_flag" => "ham"), rcpt: "<trap@example.net>")
    assert_equal [ [ "ham" ] ], @database.execute("SELECT flag FROM fuzzy_hashes")
    assert_empty @database.execute("SELECT * FROM bayes_learned")

    check(app("trap_addresses" => [ "trap@example.net" ], "trap_learn_spam" => true), rcpt: "<trap@example.net>")
    assert_equal [ [ "ham" ] ], @database.execute("SELECT flag FROM fuzzy_hashes")
    assert_equal [ [ "spam" ] ], @database.execute("SELECT class FROM bayes_learned")
  end

  def test_a_message_already_learned_as_spam_is_fine
    app = app(TRAPPING)

    2.times { assert_equal 200, check(app, rcpt: "<trap@example.net>").status }
    assert_equal [ [ "spam", 20 ] ], @database.execute("SELECT flag, count FROM fuzzy_hashes")
    assert_equal 2, stats(app)["trap_hits"]
  end

  def test_trusted_senders_are_neither_scored_nor_trapped
    app = app(TRAPPING)

    assert_empty symbols(app, rcpt: "<trap@example.net>", ip: "10.0.0.1")
    assert_empty symbols(app, rcpt: "<trap@example.net>", user: "alice")
    assert_empty @database.execute("SELECT * FROM fuzzy_hashes")
    assert_empty @database.execute("SELECT * FROM bayes_learned")
    assert_equal 0, stats(app)["trap_hits"]
  end

  def test_traps_are_off_by_default
    app = app({})

    assert_empty symbols(app, rcpt: "<trap@example.net>")
    assert_equal 0, stats(app)["trap_hits"]
  end

  def test_stats_count_trap_hits
    app = app(TRAPPING)
    check(app, rcpt: "<trap@example.net>")
    check(app, rcpt: "<bob@example.net>")

    assert_equal 1, stats(app)["trap_hits"]
  end

  def test_symbols_lists_trap
    assert_includes JSON.parse(get(app({}), "/symbols").body), { "name" => "SENT_TO_TRAP", "weight" => 10.0, "description" => "Sent to a trap address", "group" => "trap" }
  end

  private
    def app(settings)
      config = MailScore::Config.parse(SETTINGS.merge("database" => @path, "message_size_cap" => 4096, "actions" => UNGREYLISTED, **settings), env: TOKENS)
      MailScore::App.new(config, database: @database, rules: [ MailScore::Rules::Trap ])
    end

    def check(app, rcpt:, ip: "203.0.113.9", user: nil)
      headers = { "HTTP_AUTHORIZATION" => "Bearer read-token-000000000000000000000", "HTTP_RCPT" => rcpt, "HTTP_IP" => ip, "HTTP_USER" => user }.compact
      Rack::MockRequest.new(app).post("/check", headers.merge(input: "Subject: hello\n\n#{OFFER}"))
    end

    def symbols(app, **options)
      JSON.parse(check(app, **options).body)["symbols"]
    end

    def get(app, path)
      Rack::MockRequest.new(app).get(path, "HTTP_AUTHORIZATION" => "Bearer read-token-000000000000000000000")
    end

    def stats(app)
      JSON.parse(get(app, "/stats").body)
    end
end
