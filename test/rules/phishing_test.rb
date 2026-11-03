require "test_helper"

class MailScore::Rules::PhishingTest < MailScore::TestCase
  def test_link_text_showing_another_domain
    hit = run_rule(%(<a href="http://paypal.com.evil.example/login">https://www.paypal.com/</a>))

    assert_equal "LINK_TEXT_MISMATCH", hit.name
    assert_equal 4.0, hit.weight
    assert_equal "www.paypal.com links to paypal.com.evil.example", hit.detail
    assert run_rule(%(<a href="http://evil.example">www.PayPal.com</a>))
    assert run_rule(%(<a href="http://evil.example">paypal.com/signin</a>))
    assert run_rule(%(<a href="http://198.51.100.7/x">https://www.paypal.com</a>))
    assert run_rule(%(<a href="//evil.example/x">https://www.paypal.com</a>))
  end

  def test_link_text_that_starts_with_an_address
    assert run_rule(%(<a href="http://evil.example">https://www.paypal.com/, to sign in</a>))
    assert_nil run_rule(%(<a href="http://evil.example">Sign in at https://www.paypal.com</a>))
  end

  def test_a_name_written_like_a_domain_is_not_an_address
    assert_nil run_rule(%(<a href="http://click.mailer.example/Click?q=1">Shop.com</a>))
    assert_nil run_rule(%(<a href="http://www.seller.example/partner">Partner.com.</a>))
    assert_nil run_rule(%(<a href="https://files.example/1">invoice.pdf</a>))
  end

  def test_the_same_name_under_another_suffix_does_not_fire
    assert_nil run_rule(%(<a href="https://click.example.co.uk/x">www.example.co.uk</a>))
    assert_nil run_rule(%(<a href="https://www.example.de/x">www.example.com</a>))
  end

  def test_a_wrapper_naming_the_shown_domain_as_its_one_target_does_not_fire
    assert_nil run_rule(%(<a href="https://track.mailer.example/c?u=https%3A%2F%2Fwww.shop.example%2Fsale&amp;id=7">www.shop.example</a>))
    assert_nil run_rule(%(<a href="https://a.example/r?to=https%3A%2F%2Fb.example%2Fr%3Fto%3Dhttps%253A%252F%252Fshop.example%252F">www.shop.example</a>))
  end

  def test_a_wrapper_naming_another_or_several_targets_fires
    assert run_rule(%(<a href="https://track.mailer.example/c?u=https%3A%2F%2Fevil.example%2F">www.shop.example</a>))
    assert run_rule(%(<a href="https://evil.example/c?u=https://www.shop.example/&amp;v=https://evil.example/">www.shop.example</a>))
  end

  def test_a_known_redirector_plain_words_or_another_scheme_do_not_fire
    assert_nil run_rule(%(<a href="https://x.list-manage.com/track">www.shop.example</a>))
    assert_nil run_rule(%(<a href="https://evil.example">Click here</a>))
    assert_nil run_rule(%(<a href="mailto:a@example.com">www.example.com</a>))
  end

  private
    def run_rule(html)
      message = MailScore::Message.new("Content-Type: text/html\n\n#{html}")
      MailScore::Rules::Phishing.new(nil, nil).run(message, MailScore::Envelope.read({}, message))
    end
end
