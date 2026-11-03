require "test_helper"

class MailScore::Rules::HeloNotHostnameTest < MailScore::TestCase
  def test_a_helo_name_unlike_the_verified_one
    hit = run_rule("mx.example.com", "203-0-113-9.dsl.example.net")

    assert_equal "mx.example.com is not 203-0-113-9.dsl.example.net", hit.detail
    assert_equal 0.3, hit.weight
  end

  def test_matching_names_in_any_case
    assert_nil run_rule("MX.Example.com", "mx.example.com.")
  end

  def test_nothing_to_compare
    assert_nil run_rule("mx.example.com", "unknown")
    assert_nil run_rule("mx.example.com", nil)
    assert_nil run_rule("[203.0.113.9]", "mx.example.com")
    assert_nil run_rule("localhost", "mx.example.com")
    assert_nil run_rule(nil, "mx.example.com")
  end

  def test_a_trusted_sender_is_not_checked
    assert_nil run_rule("mx.example.com", "mail.example.org", user: "alice")
    assert run_rule("mx.example.com", "mail.example.org")
  end

  private
    def run_rule(helo, hostname, user: nil)
      message = MailScore::Message.new("Subject: hi\n\nbody")
      envelope = MailScore::Envelope.read({ "HTTP_HELO" => helo, "HTTP_HOSTNAME" => hostname, "HTTP_USER" => user }.compact, message)
      MailScore::Rules::HeloNotHostname.new(nil, nil).run(message, envelope)
    end
end
