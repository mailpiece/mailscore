require "test_helper"
require "mailresolver/testing"

class MailScore::Rules::DnsListsClientTest < MailScore::TestCase
  LISTS = [
    { "zone" => "zen.example", "symbol" => "ZEN", "weight" => 0,
      "returncodes" => { "ZEN_SBL" => { "weight" => 4.0, "codes" => [ "127.0.0.2" ] }, "ZEN_XBL" => { "weight" => 4.0, "codes" => [ "127.0.0.4" ] } } },
    { "zone" => "v4.example", "symbol" => "V4", "weight" => 1.0, "ipv6" => false }
  ].freeze

  class SlowResolver < MailResolver::Testing::FakeResolver
    def a(name)
      sleep 0.2
      super
    end
  end

  def test_the_client_ip_is_asked_by_its_reversed_octets
    hits = run_rule("203.0.113.9", { "9.113.0.203.zen.example" => { a: [ "127.0.0.2" ] }, "9.113.0.203.v4.example" => { a: [ "127.0.0.2" ] } })

    assert_equal [ [ "ZEN_SBL", 4.0, "203.0.113.9" ], [ "V4", 1.0, "203.0.113.9" ] ], hits.map { [ it.name, it.weight, it.detail ] }
  end

  def test_an_ipv6_client_is_asked_by_its_nibbles_of_lists_that_take_it
    dns = MailResolver::Testing::FakeResolver.new("1.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.8.b.d.0.1.0.0.2.zen.example" => { a: [ "127.0.0.4" ] })

    assert_equal [ "ZEN_XBL" ], run_rule("2001:db8::1", dns:).map(&:name)
    assert_equal 1, dns.queries.size
  end

  def test_return_codes_name_the_listing
    zone = { "9.113.0.203.zen.example" => { a: [ "127.0.0.2", "127.0.0.4", "127.0.0.99" ] } }

    assert_equal [ [ "ZEN_SBL", 4.0, "203.0.113.9" ], [ "ZEN_XBL", 4.0, "203.0.113.9" ], [ "ZEN", 0, "203.0.113.9 127.0.0.99" ] ],
      run_rule("203.0.113.9", zone).map { [ it.name, it.weight, it.detail ] }
  end

  def test_not_listed_fires_nothing_and_no_answer_fires_a_failure
    assert_empty run_rule("203.0.113.9", {})
    assert_equal [ [ "ZEN_LOOKUP_FAILED", 0.0, "203.0.113.9 timeout" ], [ "V4_LOOKUP_FAILED", 0.0, "203.0.113.9 server failure" ] ],
      run_rule("203.0.113.9", { "9.113.0.203.zen.example" => { a: :timeout }, "9.113.0.203.v4.example" => { a: :servfail } }).map { [ it.name, it.weight, it.detail ] }
  end

  def test_a_list_the_prober_has_offline_is_not_asked_until_it_comes_back
    database = MailScore::Database.new(File.join(Dir.mktmpdir, "mailscore.sqlite3"), busy_timeout: 5).tap(&:prepare)
    probe = { "1.0.0.127.zen.example" => { a: [ "127.0.0.2" ] } }
    prober = Object.new.tap { it.define_singleton_method(:a) { |name| MailResolver::Testing::FakeResolver.new(probe).a(name) } }
    monitor = MailScore::DnsList::Monitor.new(MailScore::Config.parse(SETTINGS.merge("dnsbl" => LISTS), env: TOKENS).dnsbl.first, database, dns: prober)
    listed = { "9.113.0.203.zen.example" => { a: [ "127.0.0.2" ] }, "9.113.0.203.v4.example" => { a: [ "127.0.0.2" ] } }

    3.times { monitor.probe }
    MailScore::DnsList::Monitor.read(database)
    dns = MailResolver::Testing::FakeResolver.new(listed)
    assert_equal [ "V4" ], run_rule("203.0.113.9", dns:).map(&:name)
    assert_equal [ "9.113.0.203.v4.example" ], dns.queries.map(&:first)

    probe.clear
    monitor.probe
    MailScore::DnsList::Monitor.read(database)
    assert_equal [ "ZEN_SBL", "V4" ], run_rule("203.0.113.9", listed).map(&:name)
  ensure
    database&.close
    MailScore.offline_dns_lists = nil
  end

  def test_trusted_and_local_senders_are_not_asked
    dns = MailResolver::Testing::FakeResolver.new

    assert_empty run_rule("203.0.113.9", user: "alice", dns:)
    assert_empty run_rule("10.0.0.1", dns:)
    assert_empty run_rule(nil, dns:)
    assert_empty dns.queries
  end

  def test_past_the_budget_nothing_is_asked
    dns = MailResolver::Testing::FakeResolver.new("9.113.0.203.zen.example" => { a: [ "127.0.0.2" ] })

    assert_empty run_rule("203.0.113.9", dns:, deadline: MailScore::Envelope.now - 1)
    assert_empty dns.queries
  end

  def test_queries_the_budget_runs_out_before_are_not_asked
    lists = Array.new(32) { { "zone" => "z#{it}.example", "symbol" => "Z#{it}", "weight" => 1 } }
    dns = SlowResolver.new(Array.new(32) { [ "9.113.0.203.z#{it}.example", { a: [ "127.0.0.2" ] } ] }.to_h)
    hits = run_rule("203.0.113.9", lists:, dns:, deadline: MailScore::Envelope.now + 0.1)

    assert_equal MailScore::DnsList::PARALLEL, dns.queries.size
    assert_equal MailScore::DnsList::PARALLEL, hits.size
  end

  def test_an_allow_list_spares_the_client_the_other_lists
    allow = { "zone" => "wl.example", "symbol" => "WL", "weight" => 0, "is_whitelist" => true, "whitelist_exception" => [ "WL_LOW" ],
      "returncodes" => { "WL_LOW" => { "weight" => -0.1, "codes" => [ "127%.0%.%d+%.1" ] }, "WL_MED" => { "weight" => -0.2, "codes" => [ "127%.0%.%d+%.2" ] } } }
    stubborn = { "zone" => "stubborn.example", "symbol" => "STUBBORN", "weight" => 1, "ignore_whitelist" => true }
    lists = [ LISTS.first, allow, stubborn ]
    listed = { "9.113.0.203.zen.example" => { a: [ "127.0.0.2" ] }, "9.113.0.203.stubborn.example" => { a: [ "127.0.0.2" ] } }

    dns = MailResolver::Testing::FakeResolver.new(listed.merge("9.113.0.203.wl.example" => { a: [ "127.0.15.2" ] }))
    assert_equal [ [ "WL_MED", -0.2 ], [ "STUBBORN", 1 ] ], run_rule("203.0.113.9", lists:, dns:).map { [ it.name, it.weight ] }
    assert_equal %w[ 9.113.0.203.wl.example 9.113.0.203.stubborn.example ], dns.queries.map(&:first)

    dns = MailResolver::Testing::FakeResolver.new(listed.merge("9.113.0.203.wl.example" => { a: [ "127.0.15.1" ] }))
    assert_equal %w[ WL_LOW ZEN_SBL STUBBORN ], run_rule("203.0.113.9", lists:, dns:).map(&:name)
  end

  def test_received_addresses_fire_their_own_prefixed_symbols
    zen = { "zone" => "zen.example", "symbol" => "ZEN", "weight" => { "CLIENT" => 0, "RECEIVED" => 0 },
      "checks" => %w[ from received ], "prefixes" => { "from" => "CLIENT", "received" => "RECEIVED" },
      "returncodes" => { "ZEN_SBL" => { "weight" => { "CLIENT" => 4.0, "RECEIVED" => 3.0 }, "codes" => [ "127.0.0.2" ] } } }
    headers = "Received: from mx.example.com (mx.example.com [203.0.113.9]) by mx.example.net\n" \
      "Received: from relay.example.org (relay.example.org [198.51.100.7]) by mx.example.com\n" \
      "Received: from laptop (unknown [10.1.2.3]) by relay.example.org\n"
    zone = { "9.113.0.203.zen.example" => { a: [ "127.0.0.2" ] }, "7.100.51.198.zen.example" => { a: [ "127.0.0.2", "127.0.0.9" ] } }
    dns = MailResolver::Testing::FakeResolver.new(zone)

    hits = run_rule("203.0.113.9", lists: [ zen ], headers:, dns:)
    assert_equal [ [ "CLIENT_ZEN_SBL", 4.0, "203.0.113.9" ], [ "RECEIVED_ZEN_SBL", 3.0, "198.51.100.7" ], [ "RECEIVED_ZEN", 0, "198.51.100.7 127.0.0.9" ] ],
      hits.map { [ it.name, it.weight, it.detail ] }
    assert_equal %w[ 9.113.0.203.zen.example 7.100.51.198.zen.example ], dns.queries.map(&:first)

    config = MailScore::Config.parse(SETTINGS.merge("dnsbl" => [ zen ]), env: TOKENS)
    assert_equal({ "CLIENT_ZEN" => 0, "CLIENT_ZEN_SBL" => 4.0, "RECEIVED_ZEN" => 0, "RECEIVED_ZEN_SBL" => 3.0, "ZEN_LOOKUP_FAILED" => 0.0 },
      MailScore::Rules.catalogue([ MailScore::Rules::DnsLists ], config:).to_h { [ it[:name], it[:weight] ] })
  end

  def test_only_the_top_received_headers_are_asked
    zen = { "zone" => "zen.example", "symbol" => "ZEN", "weight" => 1, "checks" => %w[ received ] }
    headers = (1..5000).map { "Received: from x ([198.51.#{it / 250}.#{it % 250}]) by y\n" }.join
    dns = MailResolver::Testing::FakeResolver.new

    run_rule("203.0.113.9", lists: [ zen ], headers:, dns:)
    assert_equal %w[ 1.0.51.198 2.0.51.198 3.0.51.198 4.0.51.198 5.0.51.198 ].map { "#{it}.zen.example" }, dns.queries.map(&:first)

    run_rule("203.0.113.9", lists: [ zen.merge("requests_limit" => 2) ], headers:, dns: dns = MailResolver::Testing::FakeResolver.new)
    assert_equal 2, dns.queries.size

    run_rule("203.0.113.9", lists: [ zen.merge("received_max_pos" => 2) ], headers:, dns: dns = MailResolver::Testing::FakeResolver.new)
    assert_equal %w[ 1.0.51.198 2.0.51.198 ].map { "#{it}.zen.example" }, dns.queries.map(&:first)
  end

  def test_a_list_that_takes_local_networks_asks_about_local_relays_too
    zen = { "zone" => "zen.example", "symbol" => "ZEN", "weight" => 1, "checks" => %w[ received ], "exclude_local" => false }
    headers = "Received: from laptop (unknown [10.1.2.3]) by relay.example.org\n"
    dns = MailResolver::Testing::FakeResolver.new

    run_rule("203.0.113.9", lists: [ zen ], headers:, dns:)
    assert_equal %w[ 3.2.1.10.zen.example ], dns.queries.map(&:first)
  end

  def test_a_hashed_list_asks_about_an_address_unhashed
    dns = MailResolver::Testing::FakeResolver.new
    run_rule("203.0.113.9", lists: [ { "zone" => "zen.example", "symbol" => "ZEN", "weight" => 1, "hash" => "sha1" } ], dns:)

    assert_equal %w[ 9.113.0.203.zen.example ], dns.queries.map(&:first)
  end

  def test_prefixes_need_one_for_each_check_and_weights_one_for_each_prefix
    zen = { "zone" => "zen.example", "symbol" => "ZEN", "weight" => { "CLIENT" => 0 }, "checks" => %w[ from ], "prefixes" => { "from" => "CLIENT" } }

    assert run_rule("192.0.2.1", lists: [ zen ])
    assert_raises(MailScore::ConfigError) { run_rule("192.0.2.1", lists: [ zen.merge("weight" => 0) ]) }
    assert_raises(MailScore::ConfigError) { run_rule("192.0.2.1", lists: [ zen.merge("checks" => %w[ from received ]) ]) }
  end

  def test_off_by_default
    dns = MailResolver::Testing::FakeResolver.new

    assert_empty run_rule("203.0.113.9", dns:, lists: [])
    assert_empty dns.queries
  end

  def test_many_lists_are_asked_together
    lists = Array.new(40) { { "zone" => "z#{it}.example", "symbol" => "Z#{it}", "weight" => 1 } }
    zone = Array.new(40) { [ "9.113.0.203.z#{it}.example", { a: [ "127.0.0.2" ] } ] }.to_h

    assert_equal Array.new(40) { "Z#{it}" }, run_rule("203.0.113.9", zone, lists:).map(&:name)
  end

  def test_the_catalogue_lists_the_configured_symbols
    config = MailScore::Config.parse(SETTINGS.merge("dnsbl" => LISTS), env: TOKENS)

    assert_equal %w[ ZEN ZEN_SBL ZEN_XBL ZEN_LOOKUP_FAILED V4 V4_LOOKUP_FAILED ], MailScore::Rules.catalogue([ MailScore::Rules::DnsLists ], config:).map { it[:name] }
    assert_empty MailScore::Rules.catalogue([ MailScore::Rules::DnsLists ])
  end

  def test_the_catalogue_leaves_a_key_out_of_the_zone
    lists = [ { "zone" => "abcdefghij0123456789klmnop.zen.dq.spamhaus.net", "symbol" => "DQS", "weight" => 1.0 } ]
    config = MailScore::Config.parse(SETTINGS.merge("dnsbl" => lists), env: TOKENS)

    descriptions = MailScore::Rules.catalogue([ MailScore::Rules::DnsLists ], config:).map { it[:description] }
    assert_equal [ "Listed in <key>.zen.dq.spamhaus.net", "Lookup in <key>.zen.dq.spamhaus.net failed" ], descriptions
  end

  private
    def run_rule(ip, zone = {}, user: nil, lists: LISTS, dns: MailResolver::Testing::FakeResolver.new(zone), deadline: nil, headers: "")
      config = MailScore::Config.parse(SETTINGS.merge("dnsbl" => lists), env: TOKENS)
      message = MailScore::Message.new("#{headers}Subject: hi\n\nbody")
      envelope = MailScore::Envelope.read({ "HTTP_IP" => ip, "HTTP_USER" => user }.compact, message, local_networks: config.local_networks)
      MailScore::Rules::DnsLists.new(config, nil, dns:).run(message, envelope.with(deadline:))
    end
end
