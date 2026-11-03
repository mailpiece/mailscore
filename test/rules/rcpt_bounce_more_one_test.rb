require "test_helper"

class MailScore::Rules::RcptBounceMoreOneTest < MailScore::TestCase
  def test_a_null_sender_to_more_than_one_recipient
    hit = run_rule("HTTP_FROM" => "<>", "HTTP_RCPT" => "a@example.net, b@example.net")

    assert_equal "BOUNCE_MANY_RECIPIENTS", hit.name
    assert_equal 1.5, hit.weight
    assert_equal "2 recipients", hit.detail
  end

  def test_a_postmaster_sender_counts_as_a_bounce
    assert run_rule("HTTP_FROM" => "<postmaster@example.com>", "HTTP_RCPT" => "a@example.net, b@example.net")
    assert run_rule("HTTP_FROM" => "<Postmaster@example.com>", "HTTP_RCPT" => "a@example.net, b@example.net")
    assert_nil run_rule("HTTP_FROM" => "<postmaster.bot@example.com>", "HTTP_RCPT" => "a@example.net, b@example.net")
  end

  def test_one_recipient_or_a_real_sender_does_not_fire
    assert_nil run_rule("HTTP_FROM" => "<>", "HTTP_RCPT" => "a@example.net")
    assert_nil run_rule("HTTP_FROM" => "<>", "HTTP_RCPT" => "a@example.net, A@example.net")
    assert_nil run_rule("HTTP_FROM" => "<sender@example.com>", "HTTP_RCPT" => "a@example.net, b@example.net")
  end

  def test_the_message_from_is_not_the_sender
    assert_nil run_rule({}, "postmaster@example.com")
  end

  def test_recipients_fall_back_to_the_message
    assert run_rule("HTTP_FROM" => "<>")
  end

  def test_a_trusted_sender_is_not_checked
    assert_nil run_rule("HTTP_FROM" => "<>", "HTTP_USER" => "alice")
  end

  private
    def run_rule(env, from = "x@example.com")
      message = MailScore::Message.new("From: #{from}\nTo: a@example.net, b@example.net\n\nbody")
      MailScore::Rules::RcptBounceMoreOne.new(nil, nil).run(message, MailScore::Envelope.read(env, message))
    end
end
