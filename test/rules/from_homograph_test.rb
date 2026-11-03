require "test_helper"

class MailScore::Rules::FromHomographTest < MailScore::TestCase
  def test_a_look_alike_sender_domain
    hit = run_rule("From: PayPal <service@pаypal.com>\n\nhello")

    assert_equal "FROM_LOOKALIKE_DOMAIN", hit.name
    assert_equal 5.0, hit.weight
    assert_equal "pаypal.com", hit.detail
    assert run_rule("From: a@example.com\n\nhello", "HTTP_FROM" => "<service@pаypal.com>")
    assert run_rule("From: a@οικο.com\n\nhello")
  end

  def test_an_xn_domain_is_judged_as_given
    assert_nil run_rule("From: PayPal <service@xn--80ak6aa92e.com>\n\nhello")
  end

  def test_only_the_domain_is_judged
    assert_nil run_rule("From: \"Аррӏе\" <аррӏе@example.com>\n\nhello")
  end

  def test_a_plain_sender_does_not_fire
    assert_nil run_rule("From: a@xn--mnchen-3ya.de\n\nhello")
    assert_nil run_rule("Subject: no sender\n\nhello", "HTTP_FROM" => "<>")
  end

  private
    def run_rule(raw, env = {})
      message = MailScore::Message.new(raw)
      MailScore::Rules::FromHomograph.new(nil, nil).run(message, MailScore::Envelope.read(env, message))
    end
end
