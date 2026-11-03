require "test_helper"

class MailScore::Rules::RedirectorUrlOnlyTest < MailScore::TestCase
  def test_one_shortened_link_and_little_text
    hit = run_rule("Subject: x\n\nhttps://bit.ly/3xYz")

    assert_equal "SHORTENED_LINK_ONLY", hit.name
    assert_equal 1.0, hit.weight
    assert_equal "bit.ly", hit.detail
  end

  def test_a_plain_link_or_a_shortener_among_text_does_not_fire
    assert_nil run_rule("Subject: x\n\nhttps://offer.example/3xYz")
    assert_nil run_rule("Subject: x\n\nThe slides from Tuesday's talk on caching are at https://bit.ly/3xYz if you missed them")
  end

  private
    def run_rule(raw)
      message = MailScore::Message.new(raw)
      MailScore::Rules::RedirectorUrlOnly.new(nil, nil).run(message, MailScore::Envelope.read({}, message))
    end
end
