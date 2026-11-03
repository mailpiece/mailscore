require "test_helper"

class MailScore::Rules::InvalidDateTest < MailScore::TestCase
  def test_a_date_that_cannot_be_read
    hit = run_rule("next tuesday")

    assert_equal "DATE_INVALID", hit.name
    assert_equal 1.5, hit.weight
    assert_equal "next tuesday", hit.detail
    assert run_rule("2026-11-03T10:00:00Z")
  end

  def test_a_readable_empty_or_missing_date
    assert_nil run_rule("Tue, 3 Nov 2026 10:00:00 +0000 (UTC)")
    assert_nil run_rule("")
    assert_nil run_rule(nil)
  end

  private
    def run_rule(date)
      message = MailScore::Message.new("#{"Date: #{date}\n" if date}Subject: hi\n\nbody")
      MailScore::Rules::InvalidDate.new(nil, nil).run(message, MailScore::Envelope.read({}, message))
    end
end
