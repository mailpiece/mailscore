require "test_helper"

class MailScore::MessageTest < MailScore::TestCase
  def test_headers_are_read_unfolded_and_case_insensitively
    message = MailScore::Message.new("Subject: one\n two\nX-Tag: a\nx-tag: b\n\nbody\n")

    assert_equal "one two", message.subject
    assert_equal [ "a", "b" ], message.header_values("X-Tag")
    assert_nil message.header("Missing")
    assert_equal "body\r\n", message.body
  end

  def test_headers_past_the_cap_are_dropped
    raw = "Subject: kept\r\n#{"X: y\r\n" * 200_000}From: dropped@example.com\r\n\r\nbody"

    message = assert_cheap(seconds: 0.5, objects: 100_000) do
      MailScore::Message.new(raw).tap { |message| 50.times { message.header_values("from") } }
    end
    assert_equal "kept", message.subject
    assert_empty message.from_addresses
    assert_equal 999, message.header_values("x").size
    assert_equal [ "TOO_MANY_HEADERS" ], message.limits.to_a
    assert_operator message.raw.bytesize, :<, 10_000
    assert message.raw.end_with?("\r\n\r\nbody")
    assert_empty MailScore::Message.new("Subject: one\n\nbody").limits
  end

  def test_header_bytes_past_the_cap_are_dropped
    message = MailScore::Message.new("Subject: kept\r\nX: #{"y" * 2_000_000}\r\nFrom: a@example.com\r\n\r\nbody")

    assert_equal "kept", message.subject
    assert message.header("x").nil?, "kept the long field"
    assert_equal [ "TOO_MANY_HEADERS" ], message.limits.to_a
  end

  def test_parts_past_the_cap_are_skipped
    raw = "Content-Type: multipart/mixed; boundary=b\r\n\r\n#{"--b\r\n\r\n" * 20_000}--b--\r\n"

    message = assert_cheap(seconds: 1, objects: 300_000) do
      MailScore::Message.new(raw).tap { it.content.text_parts }
    end
    assert_equal 1000, message.parts.size
    assert_equal [ "TOO_MANY_PARTS" ], message.limits.to_a
  end

  def test_the_part_cap_counts_nested_parts
    inner = "Content-Type: multipart/mixed; boundary=i\r\n\r\n#{"--i\r\n\r\n" * 1000}--i--"
    message = MailScore::Message.new("Content-Type: multipart/mixed; boundary=o\r\n\r\n--o\r\n#{inner}\r\n--o\r\n\r\nlast\r\n--o--\r\n")

    assert_equal 1000, message.parts.size
    assert_equal [ "TOO_MANY_PARTS" ], message.limits.to_a
    assert_empty MailScore::Message.new(raw = "Content-Type: multipart/mixed; boundary=o\r\n\r\n#{"--o\r\n\r\n" * 1000}--o--\r\n").limits
    assert_equal 1000, MailScore::Message.new(raw).parts.size
  end

  def test_nested_parts_are_read_to_a_cap_on_their_bytes
    inner = "Content-Type: application/octet-stream\r\n\r\n#{"A" * 8 * 1024 * 1024}"
    10.times { inner = "Content-Type: multipart/mixed; boundary=b#{it}\r\n\r\n--b#{it}\r\n#{inner}\r\n--b#{it}--\r\n" }

    message = assert_cheap(seconds: 1, objects: 10_000) { MailScore::Message.new(inner).tap(&:parts) }
    assert_equal 7, message.parts.size
    assert_operator message.parts.sum { it.raw.bytesize }, :<=, MailScore::Message::PART_BYTES
    assert_equal [ "TOO_MANY_PARTS" ], message.limits.to_a
    assert_equal "multipart/mixed", message.parts.last.content_type
  end

  def test_addresses_skip_display_names_and_comments
    message = MailScore::Message.new(<<~MAIL)
      From: "Fake <evil@attacker.example>" <real@bank.example> (not@this.example)
      To: a@example.com, B <b@example.com>

      body
    MAIL

    assert_equal [ "real@bank.example" ], message.from_addresses
    assert_equal [ "a@example.com", "b@example.com" ], message.to_addresses
  end

  def test_content_type_and_its_parameters
    message = MailScore::Message.new("Content-Type: Multipart/Report; report-type=delivery-status;\n boundary=\"a b\"\n\n")

    assert_equal "multipart/report", message.content_type
    assert_equal "delivery-status", message.content_type_param("Report-Type")
    assert_equal "a b", message.content_type_param("boundary")
    assert_equal "text/plain", MailScore::Message.new("Subject: x\n\nbody").content_type
  end

  def test_parts_are_found_through_nested_multiparts
    message = MailScore::Message.new(<<~MAIL)
      Content-Type: multipart/mixed; boundary=outer

      preamble
      --outer
      Content-Type: text/plain

      hello
      --outer
      Content-Type: multipart/alternative; boundary=inner

      --inner
      Content-Type: text/html

      <p>hello</p>
      --inner--
      --outer
      Content-Type: message/rfc822

      Content-Type: multipart/mixed; boundary=hidden

      --hidden
      --hidden--
      --outer--
      epilogue
    MAIL

    assert_equal %w[ text/plain multipart/alternative text/html message/rfc822 ], message.parts.map(&:content_type)
    assert_equal "hello", message.parts.first.body
  end

  def test_a_boundary_that_begins_an_inner_boundary_does_not_split_its_parts
    message = MailScore::Message.new(<<~MAIL)
      Content-Type: multipart/mixed; boundary=B

      --B
      Content-Type: multipart/alternative; boundary=B_alt

      --B_alt
      Content-Type: text/plain

      plain
      --B_alt
      Content-Type: text/html

      <p>html</p>
      --B_alt--
      --B \t
      Content-Type: application/pdf

      pdf
      --B--\t
      --B
      Content-Type: text/plain

      after the end
    MAIL

    assert_equal %w[ multipart/alternative text/plain text/html application/pdf ], message.parts.map(&:content_type)
    assert_equal [ "plain", "<p>html</p>", "pdf" ], message.parts.drop(1).map(&:body)
  end

  def test_a_part_without_a_closing_delimiter_runs_to_the_end
    message = MailScore::Message.new("Content-Type: multipart/mixed; boundary=b\n\n--b\nContent-Type: text/html\n\ncut short")

    assert_equal [ "text/html" ], message.parts.map(&:content_type)
    assert_equal "cut short", message.parts.first.body
  end

  def test_text_is_capped_and_utf8
    message = MailScore::Message.new("Subject: caf\xC3\xA9\n\n#{"a" * 300_000}\xFF".b)

    assert_equal "café", message.subject
    assert_equal MailScore::Message::TEXT_CAP, message.text.bytesize
    assert_equal Encoding::UTF_8, message.text.encoding
    assert_predicate MailScore::Message.new("\n\xFF".b).text, :valid_encoding?
  end

def test_the_subject_decodes_its_encoded_words
  subject = ->(value) { MailScore::Message.new("Subject: #{value}\n\nbody").subject }

  assert_equal "FREE MONEY NÖW", subject.("=?UTF-8?B?RlJFRSBNT05FWQ==?=\n =?utf-8?q?_N=C3=96W?=")
  assert_equal "café au lait", subject.("=?ISO-8859-1?Q?caf=E9?= au lait")
  assert_equal "Re: Übung", subject.("Re: =?UTF-8*de?Q?=C3=9Cbung?=")
  assert_equal "=?x-unknown?Q?a?= b", subject.("=?x-unknown?Q?a?= b")
  assert_equal "\uFFFD", subject.("=?UTF-8?Q?=FF?=")
  assert_equal "no words =? here", subject.("no words =? here")
end

def test_encode_words_keeps_printable_ascii_and_encodes_the_rest
  assert_equal "[spam] hello", MailScore::Message.encode_words("[spam] hello")

  encoded = MailScore::Message.encode_words("[spam] #{"é" * 40}\r\nBcc: x@example.com")
  assert_match(/\A=\?UTF-8\?B\?[A-Za-z0-9+\/=]+\?=( =\?UTF-8\?B\?[A-Za-z0-9+\/=]+\?=)+\z/, encoded)
  assert encoded.split(" ").all? { it.length <= 75 }
  assert_equal "[spam] #{"é" * 40}\r\nBcc: x@example.com", MailScore::Message.decode_words(encoded)
end

  def test_raw_keeps_the_bytes_with_crlf_line_endings
    message = MailScore::Message.new("Subject: x\n\n\xFF\n".b)

    assert_equal "Subject: x\r\n\r\n\xFF\r\n".b, message.raw
    assert_equal Encoding::BINARY, message.body.encoding
  end
end
