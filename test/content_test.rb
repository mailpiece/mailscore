require "test_helper"

class MailScore::ContentTest < MailScore::TestCase
  def test_text_parts_are_decoded_to_utf8
    content = content_of(<<~MAIL)
      Content-Type: multipart/alternative; boundary=b

      --b
      Content-Type: text/plain; charset=iso-8859-1
      Content-Transfer-Encoding: quoted-printable

      caf=E9 cr=
      =E8me
      --b
      Content-Type: text/html; charset=utf-8
      Content-Transfer-Encoding: base64

      #{[ "<p>café &amp; crème</p>" ].pack("m")}
      --b--
    MAIL

    assert_equal "café crème", content.plain.strip
    assert_equal "café & crème", content.html.first.text
    assert_equal %w[ quoted-printable base64 ], content.text_parts.map(&:encoding)
    assert content.text_parts.all? { it.text.valid_encoding? }
  end

  def test_a_bad_charset_or_bytes_are_scrubbed
    assert_equal "caf�", content_of("Content-Type: text/plain; charset=nonsense\n\ncaf\xE9".b).plain.strip
    assert_equal "+AGE-", content_of("Content-Type: text/plain; charset=utf-7\n\n+AGE-").plain.strip
  end

  def test_a_charset_is_looked_up_without_raising
    assert_cheap(seconds: 0.5, objects: 200_000) do
      20_000.times { |index| MailScore::Content.utf8("caf\xE9".b, index.even? ? "" : "x-unknown-#{index}") }
    end
    assert_equal "café", MailScore::Content.utf8("caf\xE9".b, "ISO-8859-1")
  end

  def test_decoded_text_is_capped_across_parts
    body = [ "a" * 150_000 ].pack("m")
    content = content_of("Content-Type: multipart/mixed; boundary=b\n\n--b\nContent-Transfer-Encoding: base64\n\n#{body}\n--b\n\n#{"b" * 150_000}\n--b--\n")

    assert_equal MailScore::Message::TEXT_CAP, content.text_parts.sum { it.text.bytesize }
  end

  def test_content_is_built_once
    message = MailScore::Message.new("Subject: x\n\nhello")

    assert_same message.content, message.content
  end

  def test_visible_text_falls_back_to_the_html
    assert_equal "hello", content_of("Content-Type: text/html\n\n<b>hello</b>").visible_text
    assert_equal "plain", content_of("Subject: x\n\nplain").visible_text
  end

  def test_visible_parts_keep_each_part_apart
    content = content_of("Content-Type: multipart/mixed; boundary=b\n\n--b\n\none\n--b\nContent-Type: text/html\n\n<b>html</b>\n--b\n\ntwo\n--b--\n")

    assert_equal %w[ one two ], content.visible_parts
    assert_equal "one\ntwo", content.visible_text
  end

  def test_attachments_are_named_parts_and_not_text
    content = content_of(<<~MAIL)
      Content-Type: multipart/mixed; boundary=b

      --b
      Content-Type: text/plain

      see attached
      --b
      Content-Type: text/html; name="invoice.html"

      <p>pay</p>
      --b
      Content-Type: application/octet-stream
      Content-Disposition: attachment; filename*0*=utf-8''r%C3%A9sum; filename*1=".pdf.exe"

      MZ
      --b
      Content-Type: application/octet-stream; name="=?utf-8?B?#{[ "scan.js" ].pack("m0")}?="

      x
      --b--
    MAIL

    assert_equal [ "invoice.html", "résum.pdf.exe", "scan.js" ], content.attachments.map(&:name)
    assert_equal [ "html", "exe", "js" ], content.attachments.map(&:extension)
    assert_equal [ "text/plain" ], content.text_parts.map(&:type)
  end

  def test_zip_entry_names_are_read_from_its_headers
    zip = "PK\x03\x04".b + "\0" * 22 + [ 8 ].pack("v") + "\0\0" + "evil.exe" + "data" +
      "PK\x01\x02".b + "\0" * 24 + [ 7 ].pack("v") + "\0" * 16 + "inner.7" + "PK\x03\x04".b
    content = content_of("Content-Type: application/zip; name=a.zip\nContent-Transfer-Encoding: base64\n\n#{[ zip ].pack("m")}")

    assert_equal [ "evil.exe", "inner.7" ], content.attachments.first.archive_names
    assert_empty content_of("Content-Type: application/pdf; name=a.pdf\n\n#{zip}".b).attachments.first.archive_names
  end

  def test_an_extension_is_the_file_names_last
    assert_equal [ [ "invoice.pdf", "exe" ], [ "report", "pdf" ], [ "setup", "" ], [ ".profile", "" ], [ "evil", "js" ] ],
      [ "Invoice.PDF.exe. ", "docs.d/report.pdf", "setup", ".profile", "C:\\Temp\\evil.js" ].map { MailScore::Content.split_name(it) }
  end

  def test_zip_entry_names_are_read_once_and_capped
    overlapping = (0...1000).map { "PK\x03\x04".b + "\x01".b * 22 + "\xFF\xFF".b + "\x01\x01".b + it.to_s }.join + "A" * 66_000

    names = assert_cheap(seconds: 0.5, objects: 20_000) { MailScore::Content.zip_entries(overlapping) }
    assert_equal 1, names.size
    assert_equal 255, names.first.bytesize

    long = "#{"d/" * 200}evil.exe"
    assert_equal [ long[-255..] ], MailScore::Content.zip_entries(local_header(long))
    assert_empty MailScore::Content.zip_entries(local_header("evil.exe").byteslice(0..-2))
  end

  def test_zip_entries_past_the_caps_are_skipped
    limits = Set.new
    many = (0..1000).map { local_header("#{it}.txt") }.join

    assert_equal 1000, MailScore::Content.zip_entries(many, limits:).size
    assert_equal [ "TOO_MANY_ZIP_ENTRIES" ], limits.to_a
    assert_equal 257, MailScore::Content.zip_entries((0...300).map { local_header("#{"x" * 300}#{it}") }.join).size
    assert_equal 1000, MailScore::Content.zip_entries((0...1000).map { local_header("#{it}.txt") }.join * 2, limits: limits.clear).size
    assert_empty limits
  end

  def test_zip_entries_are_capped_per_message
    zip = [ (0...1000).map { local_header("#{it}.txt") }.join ].pack("m")
    parts = (0...6).map { "--b\r\nContent-Type: application/zip; name=#{it}.zip\r\nContent-Transfer-Encoding: base64\r\n\r\n#{zip}" }
    message = MailScore::Message.new("Content-Type: multipart/mixed; boundary=b\r\n\r\n#{parts.join}--b--\r\n")

    assert_equal [ 1000, 1000, 1000, 1000, 1000, 0 ], message.content.attachments.map { it.archive_names.size }
    assert_equal [ "TOO_MANY_ZIP_ENTRIES" ], message.limits.to_a
  end

  private
    def local_header(name)
      "PK\x03\x04".b + "\0" * 22 + [ name.bytesize ].pack("v") + "\0\0" + name.b
    end

    def content_of(raw)
      MailScore::Message.new(raw).content
    end
end
