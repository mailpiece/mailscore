require "test_helper"
require "mailresolver/testing"
require "openssl"
require "rack/mock_request"
require_relative "support/mmdb"

class MailScore::ReputationTest < MailScore::TestCase
  T0 = 1_800_000_000
  DAY = 86_400
  SPAM = "reject"
  HAM = "no_action"
  SPF_RECORD = "v=spf1 include:_spf.example.net ~all"
  SCORES = { "no_action" => 0, "greylist" => 4.5, "add_header" => 7, "soft_reject" => 12, "reject" => 20 }.freeze

  def setup
    @database = MailScore::Database.new(File.join(Dir.mktmpdir, "mailscore.sqlite3"), busy_timeout: 5).tap(&:prepare)
    @reputation = reputation
  end

  def teardown
    @database.close
  end

  def test_a_dkim_detail_is_never_read_as_signers
    record(SPAM, auth: [ MailScore::Hit.new(name: "DKIM_PASS", weight: -0.1, detail: "gmail.com, x.evil.example", data: [ "x.evil.example" ]) ])

    assert_equal [ [ "dkim", "evil.example" ], [ "ip", "203.0.113.9" ] ], selectors
  end

  def test_a_selector_scores_once_its_count_reaches_the_minimum
    2.times { record(SPAM) }
    assert_empty hits

    record(SPAM)
    assert_equal [ [ "IP_REPUTATION_SPAM", 2.87, "203.0.113.9 score=0.96 count=3" ] ], hits
  end

  def test_clean_mail_scores_as_ham
    3.times { record(HAM) }

    assert_equal [ [ "IP_REPUTATION_HAM", -0.5, "203.0.113.9 score=-0.5 count=3" ] ], hits
  end

  # tanh(7.5 / 15 × 1.83178 − 0.5493) = 0.351, and 0.996 for 20 against 10.
  def test_the_score_is_the_average_stretched_over_the_reject_threshold
    @reputation = reputation("reputation_min_count" => 1)
    record_score(7.5)
    assert_equal "score=0.35", hits.first.last[/score=\S+/]

    @database.execute("DELETE FROM reputation")
    @reputation = reputation("reputation_min_count" => 1, "actions" => SETTINGS["actions"].merge("reject" => false))
    record_score(20)
    assert_equal "score=1.0", hits.first.last[/score=\S+/]
  end

  def test_the_average_moves_toward_each_score_by_the_time_since_the_last
    record_score(20)
    record_score(0, at: 30 * DAY)
    assert_equal [ [ 7.3576, 2, T0 + 30 * DAY ] ], ip_row

    record_score(0, at: 30 * DAY)
    assert_equal [ [ 7.3576, 3, T0 + 30 * DAY ] ], ip_row
  end

  def test_an_ipv4_client_counts_alone
    3.times { record(SPAM, ip: "203.0.113.9") }

    assert_equal %w[ IP_REPUTATION_SPAM ], hits(ip: "::ffff:203.0.113.9").map(&:first)
    assert_empty hits(ip: "203.0.113.200")
  end

  def test_an_ipv6_client_counts_as_its_64
    3.times { record(SPAM, ip: "2001:db8:1:2::1") }

    assert_equal [ [ "IP_REPUTATION_SPAM", 2.87, "2001:db8:1:2:: score=0.96 count=3" ] ], hits(ip: "2001:db8:1:2:ffff::1")
    assert_empty hits(ip: "2001:db8:1:3::1")
  end

  def test_the_asn_and_country_add_to_the_ip_score_by_their_factors
    @reputation = reputation("reputation_min_count" => 3, **origin_files)
    3.times { record(SPAM) }

    assert_equal [ [ "asn", "AS64500" ], [ "country", "NL" ], [ "ip", "203.0.113.9" ] ], selectors
    assert_equal [ "IP_REPUTATION_SPAM", 4.04, "203.0.113.9 score=0.96 count=3, AS64500 score=0.96 count=3, NL score=0.96 count=3" ], hits.first
    assert_equal [ "IP_REPUTATION_SPAM", 1.18, "AS64500 score=0.96 count=3, NL score=0.96 count=3" ], hits(ip: "203.0.113.200").first
  end

  def test_an_ip_the_files_do_not_know_scores_as_before
    @reputation = reputation("reputation_min_count" => 3, **origin_files)
    3.times { record(SPAM, ip: "198.51.100.7") }

    assert_equal %w[ ip ], selectors.map(&:first)
  end

  def test_without_a_client_ip_only_the_authenticated_domains_are_recorded
    record(SPAM, ip: nil, auth: [ spf_pass ])

    assert_equal [ [ "spf", spf_key ] ], selectors
  end

  def test_the_dkim_selector_is_the_organizational_domain_of_each_signer_that_passed
    record(SPAM, auth: [ dkim_pass("esp.example.net, mail.example.com, news.example.com, shop.example.co.uk") ])

    assert_equal [ [ "dkim", "example.co.uk" ], [ "dkim", "example.com" ], [ "dkim", "example.net" ] ], selectors.select { it.first == "dkim" }
  end

  def test_domains_publishing_the_same_spf_record_share_one_reputation
    2.times { record(SPAM, ip: "198.51.100.#{it}", auth: [ spf_pass("example.org") ]) }
    record(SPAM, ip: "198.51.100.2", auth: [ spf_pass("example.com") ])

    assert_equal [ [ "spf", spf_key ] ], selectors.select { it.first == "spf" }
    assert_equal [ [ "SPF_REPUTATION_SPAM", 2.86, "#{spf_key} score=0.95 count=3" ] ], hits(ip: "192.0.2.1", auth: [ spf_pass("bounces.example.net") ])
  end

  def test_a_different_spf_record_is_a_different_key
    record(SPAM, auth: [ spf_pass ])
    record(SPAM, auth: [ spf_pass("example.org", "v=spf1 ip4:192.0.2.2 -all") ])

    assert_equal [ spf_key, spf_key("v=spf1 ip4:192.0.2.2 -all") ].sort, selectors.select { it.first == "spf" }.map(&:last)
  end

  def test_an_excluded_spf_record_gets_no_reputation
    @reputation = reputation("reputation_min_count" => 3, "spf_reputation_exclusions" => [ spf_key.upcase ])
    3.times { record(SPAM, ip: nil, auth: [ spf_pass ]) }

    assert_empty selectors
    assert_empty hits(ip: nil, auth: [ spf_pass ])
  end

  def test_an_spf_pass_without_a_record_gets_no_reputation
    record(SPAM, ip: nil, auth: [ MailScore::Hit.new(name: "SPF_PASS", weight: -0.2, detail: "example.org") ])

    assert_empty selectors
  end

  def test_an_unauthenticated_domain_gets_no_reputation
    record(SPAM, auth: [ MailScore::Hit.new(name: "SPF_SOFTFAIL", weight: 0.5, detail: "example.org #{SPF_RECORD}"),
      MailScore::Hit.new(name: "DKIM_FAIL", weight: 1.0, detail: "example.com") ])

    assert_equal %w[ ip ], selectors.map(&:first)
  end

  def test_the_dkim_and_spf_selectors_score_with_their_own_symbols
    3.times { record(SPAM, ip: "198.51.100.#{it}", auth: [ dkim_pass("example.com"), spf_pass ]) }

    assert_equal [ [ "DKIM_REPUTATION_SPAM", 2.85, "example.com score=0.95 count=3" ], [ "SPF_REPUTATION_SPAM", 2.85, "#{spf_key} score=0.95 count=3" ] ],
      hits(ip: "192.0.2.1", auth: [ dkim_pass("mail.example.com"), spf_pass ])
  end

  def test_dkim_signers_add_up_to_one_score_held_between_minus_one_and_one
    3.times { record(SPAM, auth: [ dkim_pass("example.com") ]) }
    3.times { record(SPAM, auth: [ dkim_pass("example.net") ]) }
    3.times { record(HAM, auth: [ dkim_pass("example.org") ]) }

    assert_equal [ [ "DKIM_REPUTATION_SPAM", 3.0, "example.com score=0.95 count=3, example.net score=0.95 count=3" ] ],
      hits(ip: "192.0.2.1", auth: [ dkim_pass("example.com, example.net, unknown.example") ])
    assert_equal [ [ "DKIM_REPUTATION_SPAM", 1.31, "example.com score=0.95 count=3, example.org score=-0.52 count=3" ] ],
      hits(ip: "192.0.2.1", auth: [ dkim_pass("example.com, example.org") ])
  end

  def test_the_domain_comes_from_the_authentication_rules_hits
    key = OpenSSL::PKey.generate_key("ED25519")
    raw = MailAuth::Dkim.sign("From: alice@example.com\r\nSubject: hi\r\n\r\nHi.\r\n", domain: "example.com", selector: "mail", key:)
    dns = MailResolver::Testing::FakeResolver.new("mail._domainkey.example.com" => { txt: [ "v=DKIM1; k=ed25519; p=#{[ key.raw_public_key ].pack("m0")}" ] })
    message = MailScore::Message.new(raw)
    auth = MailScore::Rules::Authentication.new(nil, nil, dns:).run(message, envelope)
    @reputation.record(message, envelope, verdict(SPAM, auth), now: Time.at(T0))

    assert_includes selectors, [ "dkim", "example.com" ]
  end

  def test_an_spf_pass_that_lets_anyone_send_gives_no_reputation
    dns = MailResolver::Testing::FakeResolver.new("example.org" => { txt: [ "v=spf1 +all" ] })
    message = mail
    auth = MailScore::Rules::Authentication.new(nil, nil, dns:).run(message, envelope)
    @reputation.record(message, envelope, verdict(SPAM, auth), now: Time.at(T0))

    assert_includes auth.map(&:name), "SPF_ALLOWS_ANYONE"
    assert_equal %w[ ip ], selectors.map(&:first)
  end

  def test_trusted_senders_are_neither_recorded_nor_scored
    record(SPAM, user: "alice")
    record(SPAM, ip: "10.1.2.3")
    assert_equal 0, rows

    3.times { record(SPAM) }
    assert_empty hits(user: "alice")
  end

  def test_an_incomplete_scan_is_not_recorded
    record(SPAM, complete: false)

    assert_equal 0, rows
  end

  def test_a_greylisted_first_attempt_is_not_recorded_but_its_retry_is
    greylisted = MailScore::Hit.new(name: "GREYLISTED", weight: 0, detail: "greylisted")
    passed = MailScore::Hit.new(name: "GREYLISTED", weight: 0, detail: "pass")

    @reputation.record(mail, envelope, verdict("soft_reject", [ greylisted ]), now: Time.at(T0))
    assert_equal 0, rows

    @reputation.record(mail, envelope, verdict("greylist", [ passed ]), now: Time.at(T0 + 600))
    assert_equal [ [ 4.5, 1, T0 + 600 ] ], ip_row
  end

  def test_the_score_recorded_leaves_out_only_the_selectors_own_symbol
    own = [ MailScore::Hit.new(name: "IP_REPUTATION_SPAM", weight: 3.0), MailScore::Hit.new(name: "DKIM_REPUTATION_SPAM", weight: 2.0) ]
    @reputation.record(mail, envelope, verdict(SPAM, [ dkim_pass("example.com"), *own ], score: 10), now: Time.at(T0))

    assert_equal [ [ "dkim", 12.8 ], [ "ip", 11.8 ] ], @database.execute("SELECT selector, round(score, 2) FROM reputation ORDER BY selector")
  end

  def test_rows_expire
    record(SPAM)
    record(SPAM, ip: "198.51.100.7", at: 1)
    @database.expire(now: Time.at(T0 + 10 * DAY))

    assert_equal [ [ "198.51.100.7" ] ], @database.execute("SELECT value FROM reputation WHERE selector = 'ip'")
  end

  def test_a_scan_scores_before_it_is_recorded
    rule = Class.new(MailScore::Rule) do
      const_set(:NAME, "SPAMMY")
      const_set(:WEIGHT, 20)
      const_set(:DESCRIPTION, "Always fires")
      define_method(:run) { |_message, _envelope| MailScore::Hit.new(name: "SPAMMY", weight: 20) }
    end
    config = MailScore::Config.parse(SETTINGS.merge("reputation_min_count" => 1), env: TOKENS)
    app = MailScore::App.new(config, database: @database, rules: [ rule ], reputation: reputation("reputation_min_count" => 1))
    check = -> { JSON.parse(Rack::MockRequest.new(app).post("/check", "HTTP_AUTHORIZATION" => "Bearer read-token-000000000000000000000", "HTTP_IP" => "203.0.113.9", input: "Subject: hi\n\nbody").body) }

    assert_equal %w[ SPAMMY ], check.call["symbols"].map { it["name"] }
    assert_equal %w[ SPAMMY IP_REPUTATION_SPAM ], check.call["symbols"].map { it["name"] }
    assert_equal [ [ 2 ] ], @database.execute("SELECT count FROM reputation WHERE selector = 'ip'")
  end

  def test_a_scan_alone_records_nothing
    scanner = MailScore::Scanner.new(MailScore::Config.parse(SETTINGS, env: TOKENS), rules: [], stats: MailScore::Stats.new(@database), reputation: @reputation)
    scanner.check(mail, envelope)

    assert_equal 0, rows
  end

  def test_the_catalogue_lists_every_symbol
    assert_equal MailScore::Reputation::SYMBOLS.keys, MailScore::Rules.catalogue([ MailScore::Reputation ]).map { it[:name] }
  end

  private
    def reputation(settings = { "reputation_min_count" => 3 })
      MailScore::Reputation.new(MailScore::Config.parse(SETTINGS.merge(settings), env: TOKENS), @database)
    end

    def origin_files
      dir = Dir.mktmpdir
      { "asn_database" => File.join(dir, "asn.mmdb"), "country_database" => File.join(dir, "country.mmdb") }.tap do |files|
        MMDB.write(files["asn_database"], "GeoLite2-ASN", "203.0.113.0/24" => { "autonomous_system_number" => 64500 })
        MMDB.write(files["country_database"], "GeoLite2-Country", "203.0.113.0/24" => { "registered_country" => { "iso_code" => "NL" } })
      end
    end

    def record(action, at: 0, complete: true, auth: [], **session)
      @reputation.record(mail, envelope(**session), verdict(action, auth, complete:), now: Time.at(T0 + at))
    end

    def record_score(score, at: 0)
      @reputation.record(mail, envelope, verdict(HAM, [], score:), now: Time.at(T0 + at))
    end

    def ip_row
      @database.execute("SELECT round(score, 4), count, updated_at FROM reputation WHERE selector = 'ip'")
    end

    def hits(at: 0, auth: [], reputation: @reputation, **session)
      reputation.hits(mail, envelope(**session), auth, now: Time.at(T0 + at)).map { [ it.name, it.weight, it.detail ] }
    end

    def mail(from = "alice@example.com")
      MailScore::Message.new("From: #{from}\r\nSubject: hi\r\n\r\nbody")
    end

    def envelope(ip: "203.0.113.9", mail_from: "alice@example.org", user: nil)
      MailScore::Envelope.new(ip:, helo: "mx.example.org", hostname: nil, from: mail_from, mail_from:, recipients: [ "bob@example.net" ],
        deliver_to: nil, user:, tls_version: nil, tls_cipher: nil, queue_id: nil, deadline: nil,
        local_networks: MailScore::Config.parse(SETTINGS, env: TOKENS).local_networks)
    end

    # A verdict whose hits add up to a score that reaches +action+, unless
    # +score+ is nil.
    def verdict(action, hits, complete: true, score: SCORES.fetch(action))
      hits = [ *hits, MailScore::Hit.new(name: "RULE", weight: score) ] if score
      MailScore::Verdict.new(action:, score: hits.sum(&:weight), complete:, hits:, subject: nil)
    end

    def spf_pass(domain = "example.org", record = SPF_RECORD)
      MailScore::Hit.new(name: "SPF_PASS", weight: -0.2, detail: "#{domain} #{record}", data: record)
    end

    def spf_key(record = SPF_RECORD)
      Digest::SHA256.hexdigest(record)[0, 32]
    end

    def dkim_pass(domains)
      MailScore::Hit.new(name: "DKIM_PASS", weight: -0.2, detail: domains, data: domains.split(", "))
    end

    def selectors
      @database.execute("SELECT selector, value FROM reputation ORDER BY selector, value")
    end

    def rows
      @database.execute("SELECT count(*) FROM reputation").dig(0, 0)
    end
end
