require "test_helper"
require "mailresolver/testing"

class MailScore::DnsListMonitorTest < MailScore::TestCase
  BL = { "zone" => "bl.example", "symbol" => "BL", "weight" => 4.0 }.freeze
  PROBE = "1.0.0.127.bl.example"

  def setup
    @database = MailScore::Database.new(File.join(Dir.mktmpdir, "mailscore.sqlite3"), busy_timeout: 5).tap(&:prepare)
  end

  def teardown
    @database.close
    MailScore.offline_dns_lists = nil
  end

  def test_a_list_that_lists_its_probe_goes_offline_after_its_retries
    monitor = monitor(answering)

    2.times { monitor.probe }
    refute_predicate monitor, :offline?
    assert_empty log

    monitor.probe
    assert_predicate monitor, :offline?
    assert_match(/WARN -- : bl.example offline, not asked until its probe is not listed: listed as 127.0.0.2/, log)
  end

  def test_every_worker_reads_the_zones_the_probes_have_offline
    monitor = monitor(answering(probe = { a: [ "127.0.0.2" ] }))
    3.times { monitor.probe }

    MailScore::DnsList::Monitor.read(@database)
    assert_equal [ "bl.example" ].to_set, MailScore.offline_dns_lists

    probe[:a] = nil
    monitor.probe
    MailScore::DnsList::Monitor.read(@database)
    assert_empty MailScore.offline_dns_lists
  end

  def test_a_zone_is_recorded_offline_only_while_it_is
    monitor = monitor(answering(probe = { a: [ "127.0.0.2" ] }))

    2.times { monitor.probe }
    assert_empty offline_zones

    monitor.probe
    assert_equal [ [ "bl.example" ] ], offline_zones

    probe[:a] = nil
    monitor.probe
    assert_empty offline_zones
  end

  def test_a_restarted_prober_drops_the_rows_it_left
    @database.execute("INSERT INTO offline_dns_lists (zone) VALUES ('bl.example')")

    monitor(MailResolver::Testing::FakeResolver.new).probe

    assert_empty offline_zones
  end

  def test_a_failed_read_keeps_the_last_state
    MailScore.offline_dns_lists = [ "bl.example" ].to_set
    busy = Object.new.tap { it.define_singleton_method(:execute) { |*| raise SQLite3::BusyException } }

    assert_raises(SQLite3::BusyException) { MailScore::DnsList::Monitor.read(busy) }
    assert_equal [ "bl.example" ].to_set, MailScore.offline_dns_lists
  end

  def test_an_offline_list_comes_back_when_its_probe_is_not_listed
    monitor = monitor(answering(probe = { a: [ "127.0.0.2" ] }))
    3.times { monitor.probe }

    probe[:a] = nil
    monitor.probe

    refute_predicate monitor, :offline?
    assert_match(/INFO -- : bl.example back online/, log)
  end

  def test_timeouts_and_failures_count_as_errors_and_a_probe_not_listed_resets_them
    monitor = monitor(answering(probe = { a: :timeout }))

    monitor.probe
    probe[:a] = :servfail
    monitor.probe
    probe[:a] = nil
    monitor.probe
    probe[:a] = :servfail
    2.times { monitor.probe }
    refute_predicate monitor, :offline?

    monitor.probe
    assert_predicate monitor, :offline?
    assert_match(/bl.example offline, not asked until its probe is not listed: server failure/, log)
  end

  def test_a_list_asks_its_monitored_address_or_a_random_name
    dns = MailResolver::Testing::FakeResolver.new
    monitor(dns).probe
    monitor(dns, "monitored_address" => "2.0.0.127").probe
    monitor(dns, "checks" => [ "urls" ]).probe
    monitor(dns, "random_monitored" => true).probe

    assert_equal [ PROBE, "2.0.0.127.bl.example" ], dns.queries.first(2).map(&:first)
    assert_match(/\A[A-Za-z0-9]{8,31}\.bl\.example\z/, dns.queries[2].first)
    assert_match(/\A[A-Za-z0-9]{8,31}\.bl\.example\z/, dns.queries[3].first)
  end

  def test_each_zone_is_monitored_once_unless_disabled
    lists = parse(BL, BL.merge("symbol" => "BL2"), BL.merge("zone" => "off.example", "symbol" => "OFF", "disable_monitoring" => true))
    threads = Thread.list

    started = MailScore::DnsList::Monitor.start(lists, @database)

    assert_equal 1, started.size
    assert_equal started, Thread.list - threads
  ensure
    (Thread.list - threads).each(&:kill)
  end

  def test_a_malformed_monitored_address_fails
    [ { "monitored_address" => "" }, { "monitored_address" => "1..0" }, { "random_monitored" => "yes" }, { "disable_monitoring" => 1 } ].each do |settings|
      assert_raises(MailScore::ConfigError, settings.inspect) { parse(BL.merge(settings)) }
    end
  end

  private
    # A resolver answering the probe with +probe+, which a test may change.
    def answering(probe = { a: [ "127.0.0.2" ] })
      MailResolver::Testing::FakeResolver.new(PROBE => probe)
    end

    def offline_zones
      @database.execute("SELECT zone FROM offline_dns_lists")
    end

    def monitor(dns, settings = {})
      MailScore::DnsList::Monitor.new(parse(BL.merge(settings)).first, @database, dns:)
    end

    def parse(*lists)
      MailScore::Config.parse(SETTINGS.merge("dnsbl" => lists), env: TOKENS).dnsbl
    end
end
