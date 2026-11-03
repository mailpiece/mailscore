require "test_helper"

class MailScore::Rules::DateInPastTest < MailScore::TestCase
  NOW = Time.utc(2026, 11, 3, 10)

  def test_a_date_past_the_margin_behind
    hit = run_rule("Fri, 30 Oct 2026 10:00:00 +0000")

    assert_equal "96 hours old", hit.detail
    assert_equal 1.0, hit.weight
    assert run_rule("Tue, 03 Nov 2026 08:00:00 +0000", date_past_margin: 3600)
  end

  def test_a_date_within_the_margin_unreadable_or_missing
    assert_nil run_rule("Mon, 02 Nov 2026 10:00:00 +0000")
    assert run_rule("Mon, 02 Nov 2026 09:00:00 +0000")
    assert_nil run_rule("yesterday")
    assert_nil run_rule(nil)
  end

  private
    def run_rule(date, **settings)
      message = MailScore::Message.new("#{"Date: #{date}\n" if date}Subject: hi\n\nbody")
      config = MailScore::Config.parse(SETTINGS.merge(settings.transform_keys(&:to_s)), env: TOKENS)
      MailScore::Rules::DateInPast.new(config, nil, now: NOW).run(message, MailScore::Envelope.read({}, message))
    end
end
