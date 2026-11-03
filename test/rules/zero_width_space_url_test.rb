require "test_helper"

class MailScore::Rules::ZeroWidthSpaceUrlTest < MailScore::TestCase
  def test_a_zero_width_character_in_a_url
    hit = run_rule("Content-Type: text/plain; charset=utf-8\n\nhttps://pay​pal.example/login")

    assert_equal "LINK_ZERO_WIDTH_CHARACTER", hit.name
    assert_equal 7.0, hit.weight
    assert_equal "paypal.example", hit.detail
    assert run_rule("Content-Type: text/html\n\n<a href='https://a.example/&#x200D;x'>x</a>")
  end

  def test_a_plain_url_does_not_fire
    assert_nil run_rule("Subject: x\n\nhttps://paypal.example/login ​")
  end

  private
    def run_rule(raw)
      message = MailScore::Message.new(raw)
      MailScore::Rules::ZeroWidthSpaceUrl.new(nil, nil).run(message, MailScore::Envelope.read({}, message))
    end
end
