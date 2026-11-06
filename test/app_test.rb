require "test_helper"
require "rack/mock_request"
require "mailresolver/testing"

class MailScore::AppTest < MailScore::TestCase
  WORDS = "buy cheap pills now and save big on every order"
  SPAMMY = "Subject: x\n\n#{WORDS}"
  AGENDA = "Subject: x\n\nthe agenda for the quarterly project meeting budget review is attached here with notes"


  class ExampleRule < MailScore::Rule
    NAME = "EXAMPLE"
    GROUP = "hfilter"
    WEIGHT = 1.5
    DESCRIPTION = "Fires on example mail"

    def run(message, envelope)
      MailScore::Hit.new(name: NAME, weight: WEIGHT, detail: "<#{envelope.from}> to #{envelope.recipients.join(" ")}") if message.subject.to_s.include?("example")
    end
  end

  # SPF, DKIM, DMARC and ARC against a zone with nothing in it.
  class OfflineAuthentication < MailScore::Rules::Authentication
    def initialize(config, database)
      super(config, database, dns: MailResolver::Testing::FakeResolver.new({}))
    end
  end

  # Notes how many messages were learned when reputation recorded.
  class LearnsSeen < MailScore::Reputation
    def record(*)
      seen << @database.execute("SELECT count(*) FROM bayes_learned").dig(0, 0)
    end

    def seen
      @seen ||= []
    end
  end

  def setup
    @config = MailScore::Config.parse(SETTINGS.merge("database" => File.join(Dir.mktmpdir, "mailscore.sqlite3")), env: TOKENS)
    @database = MailScore::Database.new(@config.database, busy_timeout: @config.database_busy_timeout).tap(&:prepare)
    @app = MailScore::App.new(@config, database: @database, rules: [ ExampleRule ])
  end

  def teardown
    @database.close
  end

  def test_ping_needs_no_token
    response = get("/ping", token: nil)

    assert_equal 200, response.status
    assert_equal "text/plain", response.content_type
    assert_equal "pong", response.body
  end

  def test_health_reports_the_version
    response = get("/health")

    assert_equal 200, response.status
    assert_equal({ "status" => "ok", "version" => MailScore::VERSION }, JSON.parse(response.body))
  end

  def test_health_is_unavailable_when_the_database_does_not_open
    app = MailScore::App.new(@config, database: MailScore::Database.new("/nonexistent/mailscore.sqlite3", busy_timeout: 5))
    response = Rack::MockRequest.new(app).get("/health", "HTTP_AUTHORIZATION" => "Bearer read-token-000000000000000000000")

    assert_equal 503, response.status
    assert_equal({ "error" => "unavailable" }, JSON.parse(response.body))
  end

  def test_symbols_lists_the_catalogue
    response = get("/symbols")

    symbols = JSON.parse(response.body)

    assert_equal({ "name" => "EXAMPLE", "weight" => 1.5, "description" => "Fires on example mail", "group" => "hfilter" }, symbols.first)
    assert_equal({ "name" => "SCAN_ERROR", "weight" => 3.0, "description" => "Scan failed", "group" => "scan" }, symbols.last)
    assert_equal [ "EXAMPLE", *MailScore::Limits::SYMBOLS.keys, *MailScore::Reputation::SYMBOLS.keys, "GREYLISTED", *MailScore::Scanner::SYMBOLS.keys ], symbols.map { it["name"] }
  end

  def test_every_weight_and_score_is_a_float
    dnsbl = { "zone" => "zen.example", "symbol" => "ZEN", "weight" => 1, "returncodes" => { "ZEN_SBL" => { "weight" => 4, "codes" => [ "127.0.0.2" ] } } }
    config = MailScore::Config.parse(SETTINGS.merge("fuzzy_flags" => { "spam" => { "symbol" => "FUZZY_SPAM", "weight" => 12 } }, "dnsbl" => [ dnsbl ]), env: TOKENS)
    @app = MailScore::App.new(config, database: @database, rules: MailScore::Rules::ALL)
    symbols = JSON.parse(get("/symbols").body)
    assert_scores_are_floats symbols
    assert_empty %w[ FUZZY_SPAM GREYLISTED ZEN ZEN_SBL ] - symbols.map { it["name"] }

    config = MailScore::Config.parse(SETTINGS.merge("actions" => SETTINGS["actions"].merge("greylist" => 1)), env: TOKENS)
    @app = MailScore::App.new(config, database: @database, rules: [ ExampleRule ])
    answer = JSON.parse(check("Subject: an example\n\nbody").body)
    assert_scores_are_floats answer
    assert_equal 0.0, answer["symbols"].find { it["name"] == "GREYLISTED" }["weight"]
  end

  def test_symbols_lists_the_weight_in_use_and_marks_one_switched_off
    config = MailScore::Config.parse(SETTINGS.merge("scores" => { "EXAMPLE" => 2, "SCAN_ERROR" => false }), env: TOKENS)
    @app = MailScore::App.new(config, database: @database, rules: [ ExampleRule ])
    symbols = JSON.parse(get("/symbols").body)

    assert_equal({ "name" => "EXAMPLE", "weight" => 2.0, "description" => "Fires on example mail", "group" => "hfilter" }, symbols.first)
    assert_equal({ "name" => "SCAN_ERROR", "weight" => 3.0, "description" => "Scan failed", "group" => "scan", "disabled" => true }, symbols.last)
  end

  def test_a_score_reaches_the_verdict_reputation_and_autolearn
    settings = SETTINGS.merge("autolearn" => true, "autolearn_spam_score" => 1, "autolearn_ham_score" => -1, "scores" => { "EXAMPLE" => -2 })
    @app = MailScore::App.new(MailScore::Config.parse(settings, env: TOKENS), database: @database, rules: [ ExampleRule ])
    answer = JSON.parse(check("Subject: an example\n\n#{WORDS}", "HTTP_IP" => "203.0.113.9").body)

    assert_equal [ -2.0, [ -2.0 ] ], [ answer["score"], answer["symbols"].map { it["weight"] } ]
    assert_equal [ [ -2.0 ] ], @database.execute("SELECT score FROM reputation")
    assert_equal [ [ "ham" ] ], @database.execute("SELECT class FROM bayes_learned")
  end

  def test_check_records_the_clients_reputation
    check("Subject: an example\n\nbody", "HTTP_IP" => "203.0.113.9")

    assert_equal [ [ "ip", "203.0.113.9", 1 ] ], @database.execute("SELECT selector, value, count FROM reputation")
  end

  def test_reputation_and_autolearn_read_the_capped_weights
    settings = SETTINGS.merge("autolearn" => true, "autolearn_spam_score" => 1.2, "autolearn_ham_score" => -1, "groups" => { "hfilter" => { "max_score" => 1 } })
    @app = MailScore::App.new(MailScore::Config.parse(settings, env: TOKENS), database: @database, rules: [ ExampleRule ])
    check("Subject: an example\n\n#{WORDS}", "HTTP_IP" => "203.0.113.9")

    assert_equal [ [ 1.0 ] ], @database.execute("SELECT score FROM reputation")
    assert_equal 0, learns
  end

  def test_stats_counts_refused_requests
    get("/stats", token: "wrong")
    get("/stats", headers: { "CONTENT_LENGTH" => "1025" })

    assert_equal({ "unauthorized" => 1, "too_large" => 1 }, JSON.parse(get("/stats").body).slice("unauthorized", "too_large"))
  end

  def test_refused_requests_are_counted_without_a_write_each
    3.times { get("/stats", token: "wrong") }

    assert_empty @database.execute("SELECT value FROM counters WHERE name = 'unauthorized'")
    assert_equal 3, JSON.parse(get("/stats").body)["unauthorized"]
  end

  def test_a_header_with_invalid_utf_8_still_gets_a_verdict
    [ "mx\xff.example", "mx\xff.example".b ].each do |helo|
      response = check("Subject: x\n\nbody", "HTTP_HELO" => helo, "HTTP_FROM" => "<a\xff@example.org>", "HTTP_QUEUE_ID" => "\xff")

      assert_equal 200, response.status
      assert JSON.parse(response.body)["complete"]
    end
  end

  def test_the_log_line_cleans_and_caps_what_the_request_sent
    check("Subject: x\n\nbody", "HTTP_QUEUE_ID" => "A1\nI, forged score=-9 \e[2J#{"x" * 100}", "HTTP_IP" => "\r\n")

    line = log.lines.grep(/ scan /).sole
    assert_includes line, "scan queue_id=#{"A1I,forgedscore=-9[2J#{"x" * 100}"[0, 64]} action="
    assert_match(/ ip=-\n\z/, line)
  end

  def test_check_scans_the_message_and_its_envelope
    response = check("Subject: an example\n\nbody", "HTTP_FROM" => "<>", "HTTP_RCPT" => "a@example.net, b@example.net")

    assert_equal 200, response.status
    assert_equal({ "action" => "no action", "score" => 1.5, "complete" => true,
      "symbols" => [ { "name" => "EXAMPLE", "weight" => 1.5, "detail" => "<> to a@example.net b@example.net", "description" => "Fires on example mail" } ] },
      JSON.parse(response.body))
    assert_equal 1, JSON.parse(get("/stats").body)["scans_no_action"]
  end

  def test_check_gives_each_symbol_its_description_from_symbols
    config = MailScore::Config.parse(SETTINGS.merge("actions" => SETTINGS["actions"].merge("greylist" => 1)), env: TOKENS)
    @app = MailScore::App.new(config, database: @database, rules: [ ExampleRule ])
    symbols = JSON.parse(check("Subject: an example\n\nbody").body)["symbols"]
    descriptions = JSON.parse(get("/symbols").body).to_h { [ it["name"], it["description"] ] }

    assert_equal [ [ "EXAMPLE", "Fires on example mail" ], [ "GREYLISTED", "Held for a retry" ] ], symbols.map { [ it["name"], it["description"] ] }
    assert_equal descriptions.values_at("EXAMPLE", "GREYLISTED"), symbols.map { it["description"] }
    assert_equal %w[ name weight detail description ], symbols.first.keys
  end

  def test_check_logs_one_line_without_the_message
    check("Subject: an example\n\nbody", "HTTP_FROM" => "<sender@example.com>", "HTTP_RCPT" => "a@example.net",
      "HTTP_QUEUE_ID" => "4Xk2Lq0Rz9", "HTTP_IP" => "203.0.113.9")
    check("Subject: plain\n\nbody")

    first, second = log.lines
    assert_match(/INFO -- : scan queue_id=4Xk2Lq0Rz9 action=no_action score=1.5 complete=true ms=\d+ ip=203.0.113.9$/, first)
    assert_match(/INFO -- : scan queue_id=- action=no_action score=0.0 complete=true ms=\d+ ip=-$/, second)
    refute_match(/example\b|@|body/, log)
  end

  def test_learn_logs_its_result
    learn("spam", SPAMMY)
    learn("spam", SPAMMY)
    learn("ham", "Subject: x\n\nshort")

    assert_equal [ "learn queue_id=- class=spam result=learned ip=-", "learn queue_id=- class=spam result=already_learned ip=-",
      "learn queue_id=- class=ham result=too_short ip=-" ], log.lines.map { it.split(" -- : ").last.chomp }
  end

  def test_check_greylists_at_the_greylist_threshold
    config = MailScore::Config.parse(SETTINGS.merge("actions" => SETTINGS["actions"].merge("greylist" => 1)), env: TOKENS)
    @app = MailScore::App.new(config, database: @database, rules: [ ExampleRule ])
    answer = JSON.parse(check("Subject: an example\n\nbody", "HTTP_IP" => "203.0.113.9", "HTTP_FROM" => "a@example.org", "HTTP_RCPT" => "b@example.net").body)

    assert_equal "soft reject", answer["action"]
    assert_equal({ "name" => "GREYLISTED", "weight" => 0, "detail" => "greylisted", "description" => "Held for a retry" }, answer["symbols"].last)
    assert_equal({ "code" => 451, "enhanced" => "4.7.1", "text" => "Try again later" }, answer["smtp_reply"])
    assert_equal [ [ 2 ] ], @database.execute("SELECT count(*) FROM greylist")
  end

  def test_check_greylists_an_add_header_score_on_first_sight
    config = MailScore::Config.parse(SETTINGS.merge("actions" => SETTINGS["actions"].merge("greylist" => 1, "add_header" => 1.5)), env: TOKENS)
    @app = MailScore::App.new(config, database: @database, rules: [ ExampleRule ])
    answer = JSON.parse(check("Subject: an example\n\nbody", "HTTP_IP" => "203.0.113.9", "HTTP_FROM" => "a@example.org", "HTTP_RCPT" => "b@example.net").body)

    assert_equal [ "soft reject", "greylisted" ], [ answer["action"], answer["symbols"].last["detail"] ]
  end

  def test_check_trusts_the_configured_local_networks
    @app = MailScore::App.new(@config, database: @database, rules: [ MailScore::Rules::HostnameUnknown ])
    names = ->(ip) { JSON.parse(check("Subject: x\n\nbody", "HTTP_IP" => ip, "HTTP_HOSTNAME" => "unknown").body)["symbols"].map { it["name"] } }

    assert_empty names["10.1.2.3"]
    assert_equal %w[ HOSTNAME_UNKNOWN ], names["203.0.113.9"]
  end

  def test_check_reports_reverse_dns_without_scoring_it
    @app = MailScore::App.new(@config, database: @database, rules: [ MailScore::Rules::Rdns, MailScore::Rules::HostnameUnknown ])
    verdict = ->(headers) do
      answer = JSON.parse(check("Subject: x\n\nbody", "HTTP_IP" => "203.0.113.9", **headers).body)
      [ answer["score"], answer["symbols"].map { [ it["name"], it["weight"], it["description"] ] } ]
    end
    unknown = [ "HOSTNAME_UNKNOWN", 0.0, "Sending server has no verified host name" ]

    assert_equal [ 0.0, [ unknown ] ], verdict[{ "HTTP_HOSTNAME" => "unknown", "HTTP_REVERSE_DNS_STATUS" => "none" }]
    assert_equal [ 0.0, [ unknown ] ], verdict[{ "HTTP_HOSTNAME" => "unknown", "HTTP_REVERSE_DNS_STATUS" => "unconfirmed", "HTTP_UNCONFIRMED_HOSTNAME" => "host.example.net" }]
    assert_equal [ 0.0, [ [ "REVERSE_DNS_LOOKUP_FAILED", 0.0, "Reverse DNS lookup failed" ] ] ], verdict[{ "HTTP_REVERSE_DNS_STATUS" => "temporary_failure" }]
  end

  def test_check_takes_the_read_token
    assert_equal 401, check("Subject: x\n\nbody", token: nil).status
    assert_equal 200, check("Subject: x\n\nbody", token: "write-token-00000000000000000000").status
  end

  def test_check_refuses_an_empty_body_and_one_over_the_cap
    assert_equal({ "error" => "malformed" }, JSON.parse(check("").body))
    assert_equal 400, check("").status
    assert_equal 413, check("x" * 1025).status
    assert_equal 200, check("x" * 1024).status
  end

  def test_learn_learns_a_message_once_per_class
    response = learn("spam", SPAMMY)

    assert_equal 200, response.status
    assert_equal({ "learned" => true }, JSON.parse(response.body))

    response = learn("spam", SPAMMY)
    assert_equal 208, response.status
    assert_equal({ "error" => "already_learned" }, JSON.parse(response.body))
  end

  def test_learn_as_the_other_class_relearns
    learn("spam", SPAMMY)

    assert_equal 200, learn("ham", SPAMMY).status
    assert_equal [ [ "ham" ] ], @database.execute("SELECT class FROM bayes_learned")
  end

  def test_learn_takes_the_write_token
    response = learn("spam", SPAMMY, token: "read-token-000000000000000000000")

    assert_equal 401, response.status
    assert_equal({ "error" => "unauthorized" }, JSON.parse(response.body))
    assert_equal 401, learn("ham", SPAMMY, token: nil).status
    assert_empty @database.execute("SELECT * FROM bayes_learned")
  end

  def test_every_write_route_takes_the_write_token
    paths = MailScore::App::ROUTES.select { |_, route| MailScore::App::WRITES.include?(route) }.keys.map(&:last)

    assert_equal %w[ /fuzzy/add /fuzzy/delete /learn/spam /learn/ham ], paths
    paths.each do |path|
      response = Rack::MockRequest.new(@app).post(path, "HTTP_AUTHORIZATION" => "Bearer read-token-000000000000000000000", "HTTP_FLAG" => "spam", input: "Subject: x\n\nbody")
      assert_equal 401, response.status, path
    end
  end

  def test_a_single_token_also_learns
    config = MailScore::Config.parse(SETTINGS, env: { "MAILSCORE_READ_TOKEN" => "only-token-000000000000000000000" })
    @app = MailScore::App.new(config, database: @database)

    assert_equal 200, learn("spam", SPAMMY, token: "only-token-000000000000000000000").status
  end

  def test_learn_refuses_an_empty_body_and_one_over_the_cap
    assert_equal 400, learn("spam", "").status
    assert_equal 413, learn("spam", "x" * 1025).status
  end

  def test_learn_answers_204_and_learns_nothing_for_a_message_with_too_few_tokens
    response = learn("spam", "Subject: x\n\nbuy now")

    assert_equal 204, response.status
    assert_empty response.body
    assert_nil response.content_type
    assert_empty @database.execute("SELECT * FROM bayes_learned")
    assert_equal 0, JSON.parse(get("/stats").body)["learns_spam"]
  end

  def test_stats_count_learns
    learn("spam", SPAMMY)
    learn("spam", SPAMMY)
    learn("ham", AGENDA)

    assert_equal({ "learns_spam" => 1, "learns_ham" => 1 }, JSON.parse(get("/stats").body).slice("learns_spam", "learns_ham"))
  end

  def test_stats_show_the_fasttext_model
    assert_equal({ "trained_at" => nil, "accuracy" => nil, "spam_samples" => nil, "ham_samples" => nil }, JSON.parse(get("/stats").body)["fasttext"])

    @database.execute("INSERT INTO fasttext_trainings (trained_at, spam, ham, accuracy, swapped) VALUES (0, 300, 250, 0.97, 1)")
    assert_equal({ "trained_at" => "1970-01-01T00:00:00Z", "accuracy" => 0.97, "spam_samples" => 300, "ham_samples" => 250 },
      JSON.parse(get("/stats").body)["fasttext"])
  end

  def test_check_autolearns_when_on_and_counts_it
    settings = SETTINGS.merge("autolearn" => true, "autolearn_spam_score" => 1, "autolearn_ham_score" => -1)
    @app = MailScore::App.new(MailScore::Config.parse(settings, env: TOKENS), database: @database, rules: [ ExampleRule ])

    assert_equal 200, check("Subject: an example\n\n#{WORDS}", "HTTP_IP" => "203.0.113.9").status
    assert_equal [ [ "spam" ] ], @database.execute("SELECT class FROM bayes_learned")
    assert_equal 1, JSON.parse(get("/stats").body)["autolearns_spam"]
  end

  def test_after_the_verdict_traps_run_then_reputation_then_autolearn
    settings = SETTINGS.merge("autolearn" => true, "autolearn_spam_score" => 1, "autolearn_ham_score" => -1)
    trapping = settings.merge("trap_addresses" => [ "trap@example.net" ], "trap_learn_spam" => true)
    reputation = LearnsSeen.new(@config, @database)

    @app = MailScore::App.new(MailScore::Config.parse(settings, env: TOKENS), database: @database, rules: [ ExampleRule ], reputation:)
    check("Subject: an example\n\nfirst #{WORDS}", "HTTP_IP" => "203.0.113.9")
    @app = MailScore::App.new(MailScore::Config.parse(trapping, env: TOKENS), database: @database, rules: [ ExampleRule ], reputation:)
    check("Subject: an example\n\nsecond #{WORDS}", "HTTP_IP" => "203.0.113.9", "HTTP_RCPT" => "trap@example.net")

    # The first is autolearned after reputation; the second is trapped before it.
    assert_equal [ 0, 2 ], reputation.seen
    assert_equal 2, learns
  end

  def test_a_failure_after_the_verdict_never_costs_the_verdict
    reputation = MailScore::Reputation.new(@config, @database)
    def reputation.record(*) = raise(SQLite3::BusyException, "database is locked")
    @app = MailScore::App.new(@config, database: @database, rules: [ ExampleRule ], reputation:)

    assert_equal 200, check("Subject: an example\n\nbody", "HTTP_IP" => "203.0.113.9").status
    assert_match "ERROR -- : reputation failed: database is locked", log
  end

  def test_8bit_names_in_the_session_and_the_message_still_get_a_verdict
    @app = MailScore::App.new(@config, database: @database, rules: [ OfflineAuthentication ])
    signed = "DKIM-Signature: v=1; a=rsa-sha256; d=\xC3\xA9.example; s=s; h=from; bh=AAAA; b=AAAA\r\nFrom: a@example.net\r\n\r\nhello"
    session = { "HTTP_IP" => "203.0.113.9", "HTTP_FROM" => "a@example.net" }

    [ [ signed, {} ], [ "From: a@m\xC3\xBCnchen.de\r\n\r\nhello", session ], [ "From: a@example.net\r\n\r\nhello", session.merge("HTTP_HELO" => "mx\xFF".b) ] ].each do |raw, headers|
      response = check(raw.b, **headers)

      assert_equal 200, response.status
      assert JSON.parse(response.body)["complete"]
    end
    assert_includes JSON.parse(check("From: a@m\xC3\xBCnchen.de\r\n\r\nhello".b, **session).body)["symbols"].map { it["detail"] }, "xn--mnchen-3ya.de"
  end

  def test_a_scan_that_raises_answers_a_failed_verdict
    reputation = MailScore::Reputation.new(@config, @database)
    def reputation.hits(*) = raise(ArgumentError, "secret@example.com")
    @app = MailScore::App.new(@config, database: @database, rules: [ ExampleRule ], reputation:)
    response = check("Subject: an example\n\nbody", "HTTP_QUEUE_ID" => "4Xk2Lq0Rz9")

    assert_equal 200, response.status
    assert_equal({ "action" => "no action", "score" => 3.0, "complete" => false, "symbols" => [ { "name" => "SCAN_ERROR", "weight" => 3.0, "description" => "Scan failed" } ] },
      JSON.parse(response.body))
    assert_match "ERROR -- : scan raised ArgumentError queue_id=4Xk2Lq0Rz9", log
    refute_match "secret", log
    assert_equal 1, JSON.parse(get("/stats").body)["scan_errors"]
  end

  def test_check_does_not_autolearn_by_default
    check("Subject: an example\n\n#{WORDS}", "HTTP_IP" => "203.0.113.9")

    assert_empty @database.execute("SELECT * FROM bayes_learned")
  end

  def test_only_learned_mail_leaves_its_text_for_fasttext
    @app = MailScore::App.new(MailScore::Config.parse(SETTINGS.merge("fasttext" => true), env: TOKENS), database: @database, rules: [ ExampleRule ])

    check("Subject: an example\n\n#{WORDS}", "HTTP_IP" => "203.0.113.9")
    assert_empty @database.execute("SELECT * FROM fasttext_samples")

    learn("spam", SPAMMY)
    assert_equal [ [ "spam" ] ], @database.execute("SELECT class FROM fasttext_samples")
  end

  def test_the_write_token_also_reads
    assert_equal 200, get("/health", token: "write-token-00000000000000000000").status
  end

  def test_a_single_token_serves_both
    config = MailScore::Config.parse(SETTINGS, env: { "MAILSCORE_WRITE_TOKEN" => "only-token-000000000000000000000" })
    app = MailScore::App.new(config, database: @database)

    assert_equal 200, Rack::MockRequest.new(app).get("/health", "HTTP_AUTHORIZATION" => "Bearer only-token-000000000000000000000").status
  end

  def test_a_missing_or_wrong_token_is_unauthorized
    [ nil, "wrong", "" ].each do |token|
      response = get("/health", token: token)

      assert_equal 401, response.status
      assert_equal({ "error" => "unauthorized" }, JSON.parse(response.body))
    end
    assert_equal 401, get("/health", token: nil, headers: { "HTTP_AUTHORIZATION" => "read-token-000000000000000000000" }).status
  end

  def test_a_body_over_the_cap_is_too_large
    response = get("/health", headers: { "CONTENT_LENGTH" => "1025" })

    assert_equal 413, response.status
    assert_equal({ "error" => "too_large" }, JSON.parse(response.body))
    assert_equal 200, get("/health", headers: { "CONTENT_LENGTH" => "1024" }).status
  end

  def test_the_token_is_checked_before_the_size
    assert_equal 401, get("/health", token: nil, headers: { "CONTENT_LENGTH" => "1025" }).status
  end

  def test_an_unknown_path_is_not_found_once_authorized
    assert_equal 404, get("/check").status
    assert_equal 404, Rack::MockRequest.new(@app).post("/health", "HTTP_AUTHORIZATION" => "Bearer read-token-000000000000000000000").status
    assert_equal 401, get("/check", token: nil).status
  end

  private
    def learns
      @database.execute("SELECT count(*) FROM bayes_learned").dig(0, 0)
    end

    # Walks a JSON answer: every weight and score in it is a Float.
    def assert_scores_are_floats(json, key = nil)
      case json
      when Hash then json.each { |name, value| assert_scores_are_floats(value, name) }
      when Array then json.each { assert_scores_are_floats(it, key) }
      else assert_kind_of Float, json, key if %w[ weight score ].include?(key)
      end
    end

    def get(path, token: "read-token-000000000000000000000", headers: {})
      headers = headers.merge("HTTP_AUTHORIZATION" => "Bearer #{token}") if token
      Rack::MockRequest.new(@app).get(path, headers)
    end

    def learn(klass, raw, token: "write-token-00000000000000000000")
      headers = token ? { "HTTP_AUTHORIZATION" => "Bearer #{token}" } : {}
      Rack::MockRequest.new(@app).post("/learn/#{klass}", headers.merge(input: raw, "CONTENT_TYPE" => "message/rfc822"))
    end

    def check(raw, token: "read-token-000000000000000000000", **headers)
      headers = headers.merge("HTTP_AUTHORIZATION" => "Bearer #{token}") if token
      Rack::MockRequest.new(@app).post("/check", headers.merge(input: raw, "CONTENT_TYPE" => "message/rfc822"))
    end
end
