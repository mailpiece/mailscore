require "test_helper"

class MailScore::Rules::MultipleFromTest < MailScore::TestCase
  def test_several_addresses_in_one_from_field
    hit = run_rule("From: alice@example.com, \"Bob\" <bob@example.com>\nSubject: hi\n\nbody")

    assert_equal "alice@example.com, bob@example.com", hit.detail
    assert_equal 8.0, hit.weight
  end

  def test_one_address_in_each_of_two_from_fields
    assert run_rule("From: alice@example.com\nFrom: ceo@example.org\nSubject: hi\n\nbody")
  end

  def test_one_address_or_none
    assert_nil run_rule("From: \"Smith, Alice\" <alice@example.com>\nSubject: hi\n\nbody")
    assert_nil run_rule("Subject: hi\n\nFrom: in the body\n")
  end

  private
    def run_rule(raw)
      message = MailScore::Message.new(raw)
      MailScore::Rules::MultipleFrom.new(nil, nil).run(message, MailScore::Envelope.read({}, message))
    end
end
