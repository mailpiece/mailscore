require "test_helper"

class MailScore::Content::HtmlTest < MailScore::TestCase
  Html = MailScore::Content::Html

  def test_text_skips_tags_comments_scripts_and_styles
    html = Html.new(<<~HTML)
      <!DOCTYPE html><html><head><title>t</title><style>p { color: red }</style></head>
      <body><!-- <a href="http://hidden.example">x</a> --><p>Hello&nbsp;<b>wor</b>ld</p><div>a &lt; b &#233; &#x263A;</div>
      <script>if (a < b) { alert("x") }</script></body></html>
    HTML

    assert_equal "Hello world a < b é ☺", html.text
    assert_empty html.links
  end

  def test_links_with_their_text
    html = Html.new(%(<a class=x HREF='https://a.example/?x=1&amp;y=2'>Go <b>here</b></a> <a href=http://b.example>b<a href="http://c.example">c</a>))

    assert_equal [ [ "https://a.example/?x=1&y=2", "Go here" ], [ "http://b.example", "b" ], [ "http://c.example", "c" ] ], html.links.map { [ it.href, it.text ] }
  end

  def test_tags_and_their_attributes
    html = Html.new(%(<FORM action="http://x.example/login" method=post><input type=password></form>))

    assert_equal %w[ form input ], html.tags.map(&:name)
    assert_equal "http://x.example/login", html.tags.first["action"]
    assert_nil html.tags.first["missing"]
  end

  def test_stray_angle_brackets_are_text
    assert_equal "1 < 2 and <3 x", Html.new("1 < 2 and <3 <b>x").text
  end

  def test_unclosed_brackets_and_comments_stay_linear
    assert_cheap(seconds: 0.5, objects: 2_000_000) do
      assert_equal "", Html.new("<!--" * 50_000).text
      assert_equal "", Html.new("<style>" * 50_000).text
      assert_equal 50_000, Html.new("<!-- a>b" * 50_000).text.size
    end
    assert_equal 100_000, Html.new("<a" * 50_000).text.size
  end

  def test_comments_close_as_html5_reads_them
    link = %(<p>Hi</p><a href="http://198.51.100.7/login">http://paypal.com/login</a>)

    [ "<!-->#{link}", "<!--->#{link}", "<style><!--</style>#{link}-->", "<title><!--</title>#{link}", "<textarea><!--</textarea>#{link}",
      "<!-- never closed >#{link}" ].each do |source|
      html = Html.new(source)

      assert_equal [ "http://198.51.100.7/login" ], html.links.map(&:href), source
      assert_match "Hi", html.text, source
    end
    assert_equal "a c", Html.new("a <!-- b --> c").text
    assert_equal "a d", Html.new("a <!-- b > c --> d").text
  end
end
