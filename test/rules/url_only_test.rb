require "test_helper"

class MailScore::Rules::UrlOnlyTest < MailScore::TestCase
  def test_one_link_and_little_text
    hit = run_rule("Subject: x\n\nhey, look\nhttp://offer.example/a1b2\n")

    assert_equal "LINK_ONLY", hit.name
    assert_equal 2.2, hit.weight
    assert_equal "offer.example", hit.detail
    assert run_rule("Content-Type: text/html\n\n<a href='http://offer.example/'>click here</a>")
  end

  def test_more_text_or_more_links_does_not_fire
    assert_nil run_rule("Subject: x\n\nHi Ann, the notes from today's meeting are up at http://wiki.example/notes")
    assert_nil run_rule("Subject: x\n\nhttp://a.example http://b.example")
    assert_nil run_rule("Subject: x\n\nno links")
  end

  private
    def run_rule(raw)
      message = MailScore::Message.new(raw)
      MailScore::Rules::UrlOnly.new(nil, nil).run(message, MailScore::Envelope.read({}, message))
    end
end
