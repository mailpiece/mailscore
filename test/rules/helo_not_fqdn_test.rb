require "test_helper"

class MailScore::Rules::HeloNotFqdnTest < MailScore::TestCase
  def test_a_single_label_or_a_malformed_name
    assert_equal "OEMCOMPUTER", run_rule("OEMCOMPUTER").detail
    assert_equal 2.0, run_rule("localhost").weight
    assert_equal "mail_server.example.com", run_rule("mail_server.example.com").detail
    assert_equal "mx.example.123", run_rule("mx.example.123").detail
  end

  def test_a_dotted_name_an_address_or_no_helo
    assert_nil run_rule("mx.example.com")
    assert_nil run_rule("MX-1.Example.COM.")
    assert_nil run_rule("[203.0.113.9]")
    assert_nil run_rule("203-0-113-9")
    assert_nil run_rule(nil)
  end

  def test_without_a_client_ip_it_is_not_checked
    assert_nil run_rule("localhost", ip: nil)
    assert_nil run_rule("localhost", ip: "not an address")
  end

  def test_a_trusted_sender_is_not_checked
    assert_nil run_rule("localhost", user: "alice")
    assert run_rule("localhost")
  end

  private
    def run_rule(helo, ip: "203.0.113.9", user: nil)
      message = MailScore::Message.new("Subject: hi\n\nbody")
      env = { "HTTP_IP" => ip, "HTTP_HELO" => helo, "HTTP_USER" => user }.compact
      MailScore::Rules::HeloNotFqdn.new(nil, nil).run(message, MailScore::Envelope.read(env, message))
    end
end
