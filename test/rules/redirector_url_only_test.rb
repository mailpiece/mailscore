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

  def test_a_shorteners_file_replaces_the_list
    path = File.join(Dir.mktmpdir, "shorteners.txt").tap { File.write(it, "short.example\n") }

    assert_equal "go.short.example", run_rule("Subject: x\n\nhttps://go.short.example/3xYz", "shorteners" => path).detail
    assert_nil run_rule("Subject: x\n\nhttps://bit.ly/3xYz", "shorteners" => path)
  end

  private
    def run_rule(raw, settings = {})
      message = MailScore::Message.new(raw)
      MailScore::Rules::RedirectorUrlOnly.new(MailScore::Config.parse(SETTINGS.merge(settings), env: TOKENS), nil).run(message, MailScore::Envelope.read({}, message))
    end
end
