require "test_helper"

class MailScore::Rules::DateInFutureTest < MailScore::TestCase
  NOW = Time.utc(2026, 11, 3, 10)

  def test_a_date_past_the_margin_ahead
    hit = run_rule("Tue, 03 Nov 2026 13:30:00 +0000")

    assert_equal "3 hours ahead", hit.detail
    assert_equal 4.0, hit.weight
    assert run_rule("Tue, 03 Nov 2026 10:30:00 +0000", date_future_margin: 600)
  end

  def test_a_date_within_the_margin_unreadable_or_missing
    assert_nil run_rule("Tue, 03 Nov 2026 11:30:00 +0000")
    assert_nil run_rule("Tue, 03 Nov 2026 13:30:00 +0400")
    assert_nil run_rule("next tuesday")
    assert_nil run_rule(nil)
  end

  private
    def run_rule(date, **settings)
      message = MailScore::Message.new("#{"Date: #{date}\n" if date}Subject: hi\n\nbody")
      config = MailScore::Config.parse(SETTINGS.merge(settings.transform_keys(&:to_s)), env: TOKENS)
      MailScore::Rules::DateInFuture.new(config, nil, now: NOW).run(message, MailScore::Envelope.read({}, message))
    end
end
