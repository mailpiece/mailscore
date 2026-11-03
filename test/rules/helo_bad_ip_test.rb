require "test_helper"

class MailScore::Rules::HeloBadIpTest < MailScore::TestCase
  def test_a_private_loopback_or_reserved_address
    hit = run_rule("[192.168.1.20]")

    assert_equal "HELO_PRIVATE_IP", hit.name
    assert_equal 4.5, hit.weight
    assert_equal "[192.168.1.20]", hit.detail
    %w[ 10.0.0.1 127.0.0.1 172.20.1.1 169.254.1.1 100.64.0.1 203.0.113.9 8.8.8.255 ::1 [IPv6:fe80::1] fd00::1 2001:db8::1 ].each do |helo|
      assert run_rule(helo), helo
    end
  end

  def test_a_public_address_a_name_or_no_helo
    assert_nil run_rule("8.8.4.4")
    assert_nil run_rule("2606:4700::1")
    assert_nil run_rule("10-0-0-1")
    assert_nil run_rule("mx.example.com")
    assert_nil run_rule(nil)
  end

  def test_a_trusted_sender_is_not_checked
    assert_nil run_rule("10.0.0.1", user: "alice")
  end

  private
    def run_rule(helo, user: nil)
      message = MailScore::Message.new("Subject: hi\n\nbody")
      MailScore::Rules::HeloBadIp.new(nil, nil).run(message, MailScore::Envelope.read({ "HTTP_HELO" => helo, "HTTP_USER" => user }.compact, message))
    end
end
