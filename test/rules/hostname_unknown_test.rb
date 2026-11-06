require "test_helper"
require "mailresolver/testing"

class MailScore::Rules::HostnameUnknownTest < MailScore::TestCase
  def test_unknown_means_no_reverse_name
    hit = run_rule("unknown")

    assert_equal "203.0.113.9", hit.detail
    assert_equal 0.0, hit.weight
    assert run_rule("UNKNOWN")
  end

  def test_a_bracketed_address_or_no_header_is_looked_up
    assert_nil run_rule("[203.0.113.9]")
    assert_nil run_rule(nil)
    assert run_rule("[192.0.2.1]", ip: "192.0.2.1")
    assert run_rule(nil, ip: "192.0.2.1")
  end

  def test_a_failed_lookup_is_not_a_missing_name
    assert_nil run_rule("unknown", status: "temporary_failure")
    assert_nil run_rule(nil, ip: "192.0.2.5")
    assert run_rule("unknown", status: "none")
  end

  def test_a_name
    assert_nil run_rule("mx.example.com")
  end

  def test_a_trusted_sender_is_not_checked
    assert_nil run_rule("unknown", user: "alice")
    assert run_rule("unknown")
  end

  private
    def run_rule(hostname, user: nil, ip: "203.0.113.9", status: nil)
      message = MailScore::Message.new("Subject: hi\n\nbody")
      envelope = MailScore::Envelope.read({ "HTTP_IP" => ip, "HTTP_HOSTNAME" => hostname, "HTTP_USER" => user, "HTTP_REVERSE_DNS_STATUS" => status }.compact, message)
      dns = MailResolver::Testing::FakeResolver.new("203.0.113.9" => { ptr: [ "mx.example.com" ] }, "192.0.2.5" => { ptr: :timeout })
      MailScore::Rules::HostnameUnknown.new(nil, nil, dns:).run(message, envelope)
    end
end
