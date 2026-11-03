require "test_helper"

class MailScore::Rules::MultipleUniqueHeadersTest < MailScore::TestCase
  RAW = "From: alice@example.com\nTo: bob@example.net\nSubject: hi\nDate: Tue, 03 Nov 2026 10:00:00 +0000\n\nbody".freeze

  def test_a_repeated_field_weighs_by_its_share
    hit = run_rule("From: ceo@example.org\n#{RAW}")

    assert_equal "UNIQUE_HEADER_REPEATED", hit.name
    assert_equal 7.0, hit.weight
    assert_equal "From", hit.detail
    assert_equal 0.7, run_rule("Date: Tue, 03 Nov 2026 10:00:00 +0000\n#{RAW}").weight
    assert_equal 1.4, run_rule("To: carol@example.net\n#{RAW}").weight
  end

  def test_several_repeated_fields_weigh_by_the_worst
    hit = run_rule("Subject: hello\nTo: carol@example.net\n#{RAW}")

    assert_equal 4.9, hit.weight
    assert_equal "To, Subject", hit.detail
  end

  def test_fields_in_any_case_and_repeatable_fields
    assert run_rule("SUBJECT: hello\n#{RAW}")
    assert_nil run_rule("Received: from a\nReceived: from b\n#{RAW}")
    assert_nil run_rule(RAW)
  end

  private
    def run_rule(raw)
      message = MailScore::Message.new(raw)
      MailScore::Rules::MultipleUniqueHeaders.new(nil, nil).run(message, MailScore::Envelope.read({}, message))
    end
end
