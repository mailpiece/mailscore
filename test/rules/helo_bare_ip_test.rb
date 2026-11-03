require "test_helper"

class MailScore::Rules::HeloBareIpTest < MailScore::TestCase
  def test_a_bare_address_or_a_literal
    assert_equal "8.8.4.4", run_rule("8.8.4.4").detail
    assert_equal "[8.8.4.4]", run_rule("[8.8.4.4]").detail
    assert_equal "[IPv6:2606:4700::1]", run_rule("[IPv6:2606:4700::1]").detail
    assert_equal 3.0, run_rule("2606:4700::1").weight
  end

  def test_an_address_spelled_with_dashes
    assert_equal "8-8-4-4", run_rule("8-8-4-4").detail
    assert run_rule("[8x8x4x4]")
    assert_nil run_rule("8-8-4.example.com")
  end

  def test_a_private_or_reserved_address_is_left_to_badip
    assert_nil run_rule("10.1.2.3")
    assert_nil run_rule("[127.0.0.1]")
  end

  def test_a_name_or_no_helo
    assert_nil run_rule("mx.example.com")
    assert_nil run_rule("8.8.4.4.example.com")
    assert_nil run_rule(nil)
  end

  def test_a_trusted_sender_is_not_checked
    assert_nil run_rule("8.8.4.4", user: "alice")
    assert run_rule("8.8.4.4")
  end

  private
    def run_rule(helo, user: nil)
      message = MailScore::Message.new("Subject: hi\n\nbody")
      MailScore::Rules::HeloBareIp.new(nil, nil).run(message, MailScore::Envelope.read({ "HTTP_HELO" => helo, "HTTP_USER" => user }.compact, message))
    end
end
