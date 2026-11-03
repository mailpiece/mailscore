require "test_helper"

class MailScore::Rules::SubjAllCapsTest < MailScore::TestCase
  def test_a_subject_in_capitals_weighs_by_its_length
    hit = run_rule("BUY NOW!!! LIMITED OFFER")

    assert_equal "24 characters", hit.detail
    assert_equal 1.8, hit.weight
    assert_equal 3.0, run_rule("URGENT: YOUR ACCOUNT HAS BEEN SUSPENDED TODAY").weight
    assert_equal 0.3, run_rule("FYI!").weight
    assert run_rule("ÜBERWEISUNG BESTÄTIGT")
    assert_equal "6 characters", run_rule("=?UTF-8?B?SEVMTE8h?=").detail
    assert_nil run_rule("=?UTF-8?Q?HELLO=2C_world?=")
  end

  def test_a_reply_or_forward_prefix_is_left_out
    assert_equal "6 characters", run_rule("Re: Fwd: HELLO!").detail
    assert_equal "6 characters", run_rule("re: HELLO!").detail
    assert_nil run_rule("Re: hello")
  end

  def test_lower_case_caseless_or_no_letters
    assert_nil run_rule("Buy now, limited offer")
    assert_nil run_rule("ACHTUNG 注意")
    assert_nil run_rule("2026 !!!")
    assert_nil run_rule("")
    assert_nil run_rule(nil)
  end

  private
    def run_rule(subject)
      message = MailScore::Message.new("#{"Subject: #{subject}\n" if subject}From: a@example.com\n\nbody")
      MailScore::Rules::SubjAllCaps.new(nil, nil).run(message, MailScore::Envelope.read({}, message))
    end
end
