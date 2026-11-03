require "test_helper"

class MailScore::Content::UrlTest < MailScore::TestCase
  Url = MailScore::Content::Url

  def test_parse_reads_the_host
    url = Url.parse("http://user@WWW.Ex%41mple.com.:8080/path?q=1).")

    assert_equal "http://user@WWW.Ex%41mple.com.:8080/path?q=1", url.url
    assert_equal "http", url.scheme
    assert_equal "www.example.com", url.host
    assert_equal "www.example.com", Url.parse("www.example.com/x").host
    assert_nil Url.parse("mailto:a@example.com")
    assert_nil Url.parse("http:///path")
  end

  def test_the_host_ends_at_whitespace
    assert_equal "www.site.de", Url.parse("http://www.site.de WEB.DE").host
    assert_equal "www.site.de", Url.parse("http://www.site.de\tWEB.DE").host
    assert_equal "www.site.de", Url.parse("http://www.site.de\nWEB.DE/path").host
    assert_equal "example.com", Url.parse("https://Example.com:8443/a/b?c=d#e").host
  end

  def test_an_href_with_a_space_in_the_host_is_not_a_homograph
    content = MailScore::Message.new(%(Content-Type: text/html\n\n<a href="http://www.site.de WEB.DE">x</a> or http://www.text.de WEB.DE\n)).content

    assert_equal %w[ www.site.de www.text.de ], content.urls.map(&:host)
    refute content.urls.any?(&:homograph?)
  end

  def test_ip_hosts
    assert_predicate Url.parse("http://192.0.2.1/x"), :ip?
    assert_predicate Url.parse("http://3221225985/"), :ip?
    assert_predicate Url.parse("http://0xC0.0x00.0x02.0x01/"), :ip?
    assert_predicate Url.parse("http://[2001:db8::1]/"), :ip?
    refute_predicate Url.parse("http://192.0.2.1.example.com/"), :ip?
  end

  def test_domain_guesses_the_registrable_part
    assert_equal "example.com", Url.domain("a.b.example.com")
    assert_equal "example.co.uk", Url.domain("www.example.co.uk")
    assert_equal "localhost", Url.domain("localhost")
  end

  def test_homographs
    assert Url.homograph?("pаypal.com")
    assert Url.homograph?("www.pοypal.example")
    assert Url.homograph?("аррӏе1.com")
    refute Url.homograph?("пример.рф")
    refute Url.homograph?("example.com")
    refute Url.homograph?("1-800.example.com")
    refute Url.homograph?("123.example.com")
  end

  def test_a_host_is_judged_as_given
    refute Url.homograph?("xn--80ak6aa92e.com"), "xn-- labels are not decoded"
    refute Url.homograph?("xn--mnchen-3ya.de")
    refute Url.homograph?("203.0.113.9")
    assert Url.homograph?("[2001:db8::1]"), "invalid domain"
    assert Url.homograph?("3221225985"), "invalid domain"
    assert Url.homograph?("localhost"), "invalid domain"
  end

  def test_homographs_beyond_latin_mixed_with_cyrillic_or_greek
    assert Url.homograph?("οικο.com"), "whole-script Greek"
    assert Url.homograph?("ոսօ.com"), "whole-script Armenian"
    assert Url.homograph?("p৭ypal.com"), "Bengali digit seven as q"
    assert Url.homograph?("1२3.com"), "Devanagari digit two among ASCII digits"
    assert Url.homograph?("зз.com"), "Cyrillic ze as the digit three"
    assert Url.homograph?("pay·pal.com"), "middle dot"
    assert Url.homograph?("pay‌pal.com"), "zero-width non-joiner"
    refute Url.homograph?("аррӏе.рф"), "Cyrillic under a Cyrillic top-level domain"
  end

  def test_content_urls_come_from_hrefs_then_text
    content = MailScore::Message.new("Content-Type: multipart/alternative; boundary=b\n\n--b\n\nsee www.plain.example, or http://a.example/.\n--b\nContent-Type: text/html\n\n<a href='http://a.example/'>a</a> http://b.example\n--b--\n").content

    assert_equal %w[ http://a.example/ http://www.plain.example http://b.example ], content.urls.map(&:url)
  end

  def test_content_urls_are_capped
    message = MailScore::Message.new("Subject: x\n\n#{(1..1100).map { "http://#{it}.example/" }.join(" ")}")

    assert_equal Url::CAP, message.content.urls.size
    assert_equal [ "TOO_MANY_LINKS" ], message.limits.to_a
    assert_empty MailScore::Message.new("Subject: x\n\nhttp://a.example/").tap(&:content).limits
  end

  def test_padding_cannot_push_a_shown_link_or_a_new_domain_out
    hidden = (1..64).map { %(<a href="http://pad#{it}.example/"></a>) }.join
    same = (1..1000).map { %(http://pad.example/#{it}) }.join(" ")
    content = MailScore::Message.new("Content-Type: text/html\n\n#{hidden}#{same} <a href='http://evil.example/buy'>buy</a> http://late.example/").content

    assert_equal %w[ http://evil.example/buy http://pad.example/1 http://late.example/ ], content.urls.first(3).map(&:url)
    assert_includes content.urls.map(&:host), "pad64.example"
  end
end
