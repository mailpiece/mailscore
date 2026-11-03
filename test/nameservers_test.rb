require "test_helper"

class MailScore::NameserversTest < MailScore::TestCase
  def setup
    @answers = { "unbound" => [ "172.18.0.5" ] }
    @lookup = ->(name) { @answers.fetch(name) { raise SocketError, "getaddrinfo: Name or service not known" } }
  end

  def test_without_the_setting_dns_goes_to_the_system_resolver
    assert_nil nameservers(nil).tap(&:resolve).addresses
    assert_nil MailScore.nameservers.addresses
  end

  def test_addresses_pass_without_a_lookup
    lookup = ->(name) { flunk "looked up #{name}" }

    assert_equal [ "192.0.2.53", "2001:db8::53" ], nameservers([ "192.0.2.53", "2001:db8::53" ], lookup:).tap(&:resolve).addresses
  end

  def test_a_host_name_resolves_to_its_addresses
    @answers["unbound"] = [ "172.18.0.5", "fd00::5" ]

    assert_equal [ "172.18.0.5", "fd00::5", "192.0.2.53" ], nameservers([ "unbound", "192.0.2.53" ]).tap(&:resolve).addresses
  end

  def test_a_refresh_picks_up_a_changed_address
    nameservers = nameservers([ "unbound" ]).tap(&:resolve)
    @answers["unbound"] = [ "172.18.0.9" ]

    nameservers.refresh

    assert_equal [ "172.18.0.9" ], nameservers.addresses
  end

  def test_a_failed_refresh_keeps_the_last_addresses_and_warns
    nameservers = nameservers([ "unbound" ]).tap(&:resolve)
    @answers.delete("unbound")

    nameservers.refresh

    assert_equal [ "172.18.0.5" ], nameservers.addresses
    assert_match(/WARN -- : nameservers refresh failed: getaddrinfo/, log)
  end

  def test_a_name_that_does_not_resolve_at_boot_is_a_config_error
    error = assert_raises(MailScore::ConfigError) { nameservers([ "missing" ]).resolve }
    assert_equal "nameservers: getaddrinfo: Name or service not known", error.message
  end

  def test_the_refresh_runs_in_the_background
    nameservers = nameservers([ "unbound" ]).tap(&:resolve)
    @answers["unbound"] = [ "172.18.0.9" ]

    thread = nameservers.refresh_every(60)
    50.times { break if nameservers.addresses == [ "172.18.0.9" ]; sleep 0.01 }

    assert_equal [ "172.18.0.9" ], nameservers.addresses
  ensure
    thread&.kill
  end

  def test_without_the_setting_nothing_refreshes
    assert_nil nameservers(nil).refresh_every(60)
  end

  private
    def nameservers(entries, lookup: @lookup)
      MailScore::Nameservers.new(entries, lookup:)
    end
end
