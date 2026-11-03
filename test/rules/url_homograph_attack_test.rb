require "test_helper"

class MailScore::Rules::UrlHomographAttackTest < MailScore::TestCase
  def test_a_mixed_script_host
    hit = run_rule("Content-Type: text/html; charset=utf-8\n\n<a href='https://pаypal.com/'>PayPal</a>")

    assert_equal "LINK_LOOKALIKE_DOMAIN", hit.name
    assert_equal 5.0, hit.weight
    assert_equal "pаypal.com", hit.detail
  end

  def test_an_ascii_or_single_script_host_does_not_fire
    assert_nil run_rule("Subject: x\n\nhttps://paypal.com/ http://123.example.com/ https://пример.рф/")
  end

  def test_a_host_is_judged_as_given
    assert_nil run_rule("Subject: x\n\nhttps://xn--80ak6aa92e.com/id http://203.0.113.9/")
    assert_equal "[2001:db8::1]", run_rule("Subject: x\n\nhttp://[2001:db8::1]/").detail
    assert_equal "localhost", run_rule("Subject: x\n\nhttp://localhost/").detail
  end

  def test_a_whole_script_look_alike_host
    assert_equal "οικο.com", run_rule("Subject: x\n\nhttps://οικο.com/login").detail
  end

  private
    def run_rule(raw)
      message = MailScore::Message.new(raw)
      MailScore::Rules::UrlHomographAttack.new(nil, nil).run(message, MailScore::Envelope.read({}, message))
    end
end
