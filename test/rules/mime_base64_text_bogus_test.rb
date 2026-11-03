require "test_helper"

class MailScore::Rules::MimeBase64TextBogusTest < MailScore::TestCase
  def test_ascii_text_in_base64
    hit = run_rule("Content-Type: text/html\nContent-Transfer-Encoding: base64\n\n#{[ "<p>Buy now</p>" ].pack("m")}")

    assert_equal "TEXT_IN_BASE64", hit.name
    assert_equal 1.0, hit.weight
    assert_equal "text/html", hit.detail
  end

  def test_non_ascii_or_unencoded_text_does_not_fire
    assert_nil run_rule("Content-Type: text/plain; charset=utf-8\nContent-Transfer-Encoding: base64\n\n#{[ "café" ].pack("m")}")
    assert_nil run_rule("Content-Type: text/plain\n\nBuy now")
    assert_nil run_rule("Content-Type: application/pdf; name=a.pdf\nContent-Transfer-Encoding: base64\n\n#{[ "plain" ].pack("m")}")
  end

  private
    def run_rule(raw)
      message = MailScore::Message.new(raw)
      MailScore::Rules::MimeBase64TextBogus.new(nil, nil).run(message, MailScore::Envelope.read({}, message))
    end
end
