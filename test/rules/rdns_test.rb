require "test_helper"
require "mailresolver/testing"

class MailScore::Rules::RdnsTest < MailScore::TestCase
  ZONE = {
    "203.0.113.9" => { ptr: [ "MX.Example.com.", "other.example.com" ] },
    "2001:db8::9" => { ptr: [ "mx6.example.com" ] },
    "192.0.2.5" => { ptr: :timeout }
  }.freeze

  def test_the_first_ptr_name_stands_in_for_the_hostname_unchecked
    dns = MailResolver::Testing::FakeResolver.new(ZONE)

    assert_equal [], names(ip: "203.0.113.9", helo: "mx.example.com", dns:)
    assert_equal [], names(ip: "2001:db8::9", helo: "mx6.example.com")
    assert_equal "mail.example.org is not mx.example.com", run_rules(ip: "203.0.113.9", helo: "mail.example.org").first.detail
    assert_equal [ [ "203.0.113.9", :ptr ] ], dns.queries
  end

  def test_no_ptr_record
    hits = run_rules(ip: "192.0.2.1", helo: "mx.example.com")

    assert_equal [ [ "REVERSE_DNS_NONE", 2.0, "192.0.2.1" ], [ "HOSTNAME_UNKNOWN", 2.5, "192.0.2.1" ] ], hits.map { [ it.name, it.weight, it.detail ] }
  end

  def test_a_failed_lookup_says_nothing_either_way
    expected = [ [ "REVERSE_DNS_LOOKUP_FAILED", 0.0 ] ]

    assert_equal expected, run_rules(ip: "192.0.2.5", helo: "mx.example.com").map { [ it.name, it.weight ] }
    assert_equal expected, run_rules(ip: "192.0.2.1", zone: { "192.0.2.1" => { ptr: :servfail } }).map { [ it.name, it.weight ] }
  end

  def test_a_temporary_failure_from_the_caller_says_nothing_either_way_and_is_not_looked_up_again
    dns = MailResolver::Testing::FakeResolver.new(ZONE)

    assert_equal [ "REVERSE_DNS_LOOKUP_FAILED" ], names(ip: "203.0.113.9", status: "temporary_failure", dns:)
    assert_equal [ "REVERSE_DNS_LOOKUP_FAILED" ], names(ip: "192.0.2.1", hostname: "[192.0.2.1]", status: "Temporary_Failure", dns:)
    assert_equal [ "REVERSE_DNS_LOOKUP_FAILED" ], names(ip: "192.0.2.1", hostname: "unknown", status: "temporary_failure", dns:)
    assert_empty dns.queries
  end

  def test_without_a_status_mailscore_looks_up_itself
    dns = MailResolver::Testing::FakeResolver.new(ZONE)

    assert_empty names(ip: "203.0.113.9", helo: "mx.example.com", dns:)
    assert_equal [ [ "203.0.113.9", :ptr ] ], dns.queries
  end

  def test_any_other_status_from_the_caller_changes_nothing
    assert_equal [ "HOSTNAME_UNKNOWN" ], names(ip: "192.0.2.1", hostname: "unknown", status: "none")
    assert_equal %w[ REVERSE_DNS_NONE HOSTNAME_UNKNOWN ], names(ip: "192.0.2.1", hostname: "[192.0.2.1]", status: "none")
    assert_equal [ "HOSTNAME_UNKNOWN" ], names(ip: "192.0.2.1", hostname: "unknown", status: "unconfirmed")
    assert_equal [ "HOSTNAME_UNKNOWN" ], names(ip: "192.0.2.1", hostname: "unknown", status: "timeout")
    assert_equal %w[ REVERSE_DNS_NONE HOSTNAME_UNKNOWN ], names(ip: "192.0.2.1", status: "confirmed")
  end

  def test_the_scan_looks_up_once
    dns = MailResolver::Testing::FakeResolver.new(ZONE)
    run_rules(ip: "203.0.113.9", helo: "mail.example.org", dns:)

    assert_equal [ [ "203.0.113.9", :ptr ] ], dns.queries
  end

  def test_a_bracketed_address_counts_as_no_hostname
    assert_equal [ "HELO_HOSTNAME_MISMATCH" ], names(ip: "203.0.113.9", helo: "mail.example.org", hostname: "[203.0.113.9]")
    assert_equal %w[ REVERSE_DNS_NONE HOSTNAME_UNKNOWN ], names(ip: "192.0.2.1", hostname: "[192.0.2.1]")
  end

  def test_a_hostname_from_the_caller_is_not_looked_up
    dns = MailResolver::Testing::FakeResolver.new(ZONE)

    assert_equal [ "HELO_HOSTNAME_MISMATCH" ], run_rules(ip: "192.0.2.1", helo: "mx.example.com", hostname: "mail.example.org", dns:).map(&:name)
    assert_equal [ "HOSTNAME_UNKNOWN" ], run_rules(ip: "192.0.2.1", hostname: "unknown", dns:).map(&:name)
    assert_empty dns.queries
  end

  def test_a_trusted_sender_or_no_client_ip_is_not_looked_up
    dns = MailResolver::Testing::FakeResolver.new(ZONE)

    assert_empty run_rules(ip: "192.0.2.1", user: "alice", dns:)
    assert_empty run_rules(ip: "192.0.2.1", user: "alice", status: "temporary_failure", dns:)
    assert_empty run_rules(ip: "10.0.0.1", dns:)
    assert_empty run_rules(ip: nil, helo: "mx.example.com", dns:)
    assert_empty dns.queries
  end

  private
    RULES = [ MailScore::Rules::Rdns, MailScore::Rules::HeloNotHostname, MailScore::Rules::HostnameUnknown ].freeze

    def names(**options)
      run_rules(**options).map(&:name)
    end

    def run_rules(ip:, helo: nil, hostname: nil, status: nil, user: nil, zone: ZONE, dns: MailResolver::Testing::FakeResolver.new(zone), deadline: nil)
      message = MailScore::Message.new("Subject: hi\n\nbody")
      env = { "HTTP_IP" => ip, "HTTP_HELO" => helo, "HTTP_HOSTNAME" => hostname, "HTTP_REVERSE_DNS_STATUS" => status, "HTTP_USER" => user }.compact
      envelope = MailScore::Envelope.read(env, message, local_networks: [ IPAddr.new("10.0.0.0/8") ]).with(deadline:)

      RULES.flat_map { Array(it.new(nil, nil, dns:).run(message, envelope)) }
    end
end
