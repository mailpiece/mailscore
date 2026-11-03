require "test_helper"

class MailScore::FuzzyTest < MailScore::TestCase
  OFFER = "Dear customer, your account has been selected for an exclusive reward. To claim the prize, confirm your details " \
    "at https://reward.example.com/claim?id=123&ref=abc before the end of the week. Our team reviews every claim within " \
    "two working days and sends the reward by courier to the address you confirm. Do not reply to this message, as the " \
    "mailbox is not monitored. Thank you for being a valued member of our loyalty programme."
  NEWSLETTER = "The garden club meets on Thursday evening in the village hall to plan the spring planting. Members are asked " \
    "to bring seedlings, spare pots and any tools they can lend for the community beds along the river path. After the " \
    "meeting there will be tea, a short talk on composting and a chance to swap seeds collected over the autumn months."

  def setup
    @config = MailScore::Config.parse(SETTINGS.merge("database" => File.join(Dir.mktmpdir, "mailscore.sqlite3")), env: TOKENS)
    @database = MailScore::Database.new(@config.database, busy_timeout: @config.database_busy_timeout).tap(&:prepare)
    @fuzzy = MailScore::Fuzzy.new(@config, @database)
  end

  def teardown
    @database.close
  end

  def test_normalizing_lowercases_strips_query_strings_and_collapses_whitespace
    assert_equal %w[ see https://example.com/a now ], MailScore::Fuzzy.words("See \n HTTPS://Example.com/a?b=c#d\tNOW")
  end

  def test_shingles_are_32_min_hashes_tagged_with_their_index
    shingles = MailScore::Fuzzy.shingles(OFFER.split)

    assert_equal 32, shingles.size
    assert_equal (0...32).to_a, shingles.map { it >> 58 }
    assert_equal shingles, MailScore::Fuzzy.shingles(OFFER.split)
  end

  def test_a_near_duplicate_matches_above_the_threshold
    @fuzzy.add(mail(OFFER), "spam")
    variant = OFFER.sub("Dear customer", "Dear friend").sub("two working days", "three working days").sub("?id=123", "?id=987")
    match, = @fuzzy.check(mail(variant))

    assert_equal "spam", match.flag
    assert_equal 1, match.count
    assert_operator match.similarity, :>, 0.5
    assert_operator match.similarity, :<, 1.0
  end

  def test_a_near_duplicate_needs_more_than_half_the_shingles
    @fuzzy.add(mail(OFFER), "spam")
    @database.execute("UPDATE fuzzy_hashes SET hash = 'stored'")
    @database.execute("UPDATE fuzzy_shingles SET hash = 'stored'")
    @database.execute("DELETE FROM fuzzy_shingles WHERE shingle >> 58 >= 17")

    assert_equal [ 0.53 ], @fuzzy.check(mail(OFFER)).map(&:similarity)

    @database.execute("DELETE FROM fuzzy_shingles WHERE shingle >> 58 = 16")
    assert_empty @fuzzy.check(mail(OFFER))
  end

  def test_the_same_text_matches_exactly
    @fuzzy.add(mail(OFFER), "spam")

    assert_equal [ MailScore::Fuzzy::Match.new(flag: "spam", count: 1, similarity: 1.0) ], @fuzzy.check(mail(OFFER.upcase))
  end

  def test_a_different_text_does_not_match
    @fuzzy.add(mail(OFFER), "spam")

    assert_empty @fuzzy.check(mail(NEWSLETTER))
  end

  def test_short_text_is_skipped
    assert_equal 0, @fuzzy.add(mail("Buy now, limited offer"), "spam")
    assert_equal [ [ 0 ] ], @database.execute("SELECT count(*) FROM fuzzy_hashes")
  end

  def test_a_short_text_is_hashed_exactly_with_its_subject
    short = "Your parcel remains undeliverable. Outstanding customs clearance charges of 1.99 require immediate settlement " \
      "through https://parcel.example.com/pay?id=7 otherwise the international shipment returns automatically. Reply STOP " \
      "unsubscribing notifications regarding delivery tracking."

    assert_equal 1, @fuzzy.add(mail(short), "spam")
    assert_equal [ [ 0 ] ], @database.execute("SELECT count(*) FROM fuzzy_shingles")
    assert_equal [ 1.0 ], @fuzzy.check(mail(short.upcase.sub("?id=7", "?id=8"))).map(&:similarity)
    assert_empty @fuzzy.check(mail(short, subject: "another subject"))
    assert_empty @fuzzy.check(mail(short.sub("1.99", "2.99")))
    assert_equal [ 1.0 ], @fuzzy.check(mail(short, subject: "=?UTF-8?Q?hello?=")).map(&:similarity)
  end

  def test_a_short_text_needs_a_quarter_of_the_minimum_size_with_its_subject
    text = "abcdefgh " * 25

    assert_equal 0, @fuzzy.add(mail(text.strip, subject: "x" * 31), "spam")
    assert_equal 1, @fuzzy.add(mail(text.strip, subject: "x" * 32), "spam")
  end

  def test_a_base64_text_part_too_short_to_shingle_is_hashed_and_a_small_image_is_not
    note = "Wonderful photographs attached: remarkable roses, magnificent sunflowers, extraordinary hollyhocks, beautiful " \
      "delphiniums everywhere. Grandmother insisted photographing everything before tonight's thunderstorms arrive. " \
      "Absolutely unforgettable afternoon."
    raw = multipart([ part("text/plain", note), part("image/png", png(120, 40)) ])

    assert_equal 1, @fuzzy.add(MailScore::Message.new(raw), "spam")
    assert_equal [ 1.0 ], @fuzzy.check(MailScore::Message.new("Subject: files\n\n#{note}")).map(&:similarity)
  end

  def test_an_html_part_is_hashed_by_its_visible_text
    @fuzzy.add(mail("<p>#{OFFER}</p>", type: "text/html"), "spam")

    assert_equal [ 1.0 ], @fuzzy.check(mail(OFFER)).map(&:similarity)
  end

  def test_attachments_and_inline_images_match_by_exact_hash
    pdf, image = "%PDF-1.7 #{"x" * 2000}", png(800, 600)
    raw = multipart([ part("application/pdf", pdf, name: "invoice.pdf"), part("image/png", image), part("image/gif", "GIF89a") ])

    assert_equal 2, @fuzzy.add(MailScore::Message.new(raw), "spam")
    assert_equal [ 1.0 ], @fuzzy.check(MailScore::Message.new(multipart([ part("image/png", image, name: "other.png") ]))).map(&:similarity)
    assert_empty @fuzzy.check(MailScore::Message.new(multipart([ part("image/png", png(800, 600, fill: "\1")) ])))
  end

  def test_only_application_attachments_are_hashed
    body = "x" * 2000
    raw = multipart([ part("application/octet-stream", body, name: "a.bin"), part("text/csv", body, name: "a.csv"),
      part("audio/mpeg", body, name: "a.mp3"), part("application/zip", "PK", name: "small.zip"), part("application/pdf", "%PDF #{body}") ])

    assert_equal 1, @fuzzy.add(MailScore::Message.new(raw), "spam")
  end

  def test_images_need_500_pixels_each_way
    gif = ->(width, height) { "GIF89a#{[ width, height ].pack("vv")}#{"\0" * 2000}".b }
    raw = multipart([ part("image/png", png(500, 499)), part("image/png", png(499, 500)), part("image/gif", gif[640, 480]),
      part("image/png", "\x89PNG#{"\0" * 2000}".b), part("image/png", png(500, 500), name: "photo.png"), part("image/gif", gif[500, 500]) ])

    assert_equal 2, @fuzzy.add(MailScore::Message.new(raw), "spam")
  end

  def test_dimensions_are_read_from_png_gif_and_jpeg_headers
    jpeg = "\xFF\xD8\xFF\xE0\x00\x10JFIF\x00\x01\x01\x00\x00\x01\x00\x01\x00\x00\xFF\xDB\x00\x04\x00\x00" \
      "\xFF\xC2\x00\x11\x08\x02\x58\x03\x20\x03\x01\x22\x00".b

    assert_equal [ 800, 600 ], MailScore::Fuzzy.dimensions(png(800, 600))
    assert_equal [ 640, 480 ], MailScore::Fuzzy.dimensions("GIF87a\x80\x02\xE0\x01".b)
    assert_equal [ 800, 600 ], MailScore::Fuzzy.dimensions(jpeg)
    assert_nil MailScore::Fuzzy.dimensions(jpeg.byteslice(0, 30))
    assert_nil MailScore::Fuzzy.dimensions("\x89PNG\r\n\x1A\n".b)
    assert_nil MailScore::Fuzzy.dimensions("BM#{"\0" * 2000}".b)
  end

  def test_adding_again_counts_up_and_delete_removes_the_flag
    2.times { @fuzzy.add(mail(OFFER), "spam") }
    @fuzzy.add(mail(OFFER), "ham")

    assert_equal [ [ "ham", 1 ], [ "spam", 2 ] ], @fuzzy.check(mail(OFFER)).map { [ it.flag, it.count ] }.sort
    assert_equal 1, @fuzzy.delete(mail(OFFER), "spam")
    assert_equal [ "ham" ], @fuzzy.check(mail(OFFER)).map(&:flag)
    assert_equal [ [ 32 ] ], @database.execute("SELECT count(*) FROM fuzzy_shingles")
    assert_equal 1, @fuzzy.delete(mail(OFFER), "spam")
    assert_equal [ "ham" ], @fuzzy.check(mail(OFFER)).map(&:flag)
  end

  def test_add_can_count_more_than_one
    @fuzzy.add(mail(OFFER), "spam", count: 10)
    @fuzzy.add(mail(OFFER), "spam", count: 3)

    assert_equal [ 13 ], @fuzzy.check(mail(OFFER)).map(&:count)
  end

  def test_delete_answers_the_hash_count_like_add
    assert_equal 1, @fuzzy.delete(mail(OFFER), "spam")
    assert_equal 1, @fuzzy.add(mail(OFFER), "spam")
    assert_equal 1, @fuzzy.delete(mail(OFFER), "ham")
    assert_equal 1, @fuzzy.delete(mail(OFFER), "spam")
    assert_empty @fuzzy.check(mail(OFFER))
    assert_equal 0, @fuzzy.delete(mail("too short"), "spam")
  end

  def test_add_and_delete_write_all_or_nothing
    @fuzzy.add(mail(OFFER), "spam")
    fail_on(/\ADELETE FROM fuzzy_hashes/) { assert_raises(SQLite3::Exception) { @fuzzy.delete(mail(OFFER), "spam") } }
    assert_equal [ [ 1, 32 ] ], @database.execute("SELECT (SELECT count(*) FROM fuzzy_hashes), (SELECT count(*) FROM fuzzy_shingles)")

    @fuzzy.delete(mail(OFFER), "spam")
    fail_on(/\A\s*INSERT INTO fuzzy_shingles/) { assert_raises(SQLite3::Exception) { @fuzzy.add(mail(OFFER), "spam") } }
    assert_equal [ [ 0, 0 ] ], @database.execute("SELECT (SELECT count(*) FROM fuzzy_hashes), (SELECT count(*) FROM fuzzy_shingles)")
  end

  def test_only_the_best_match_per_flag_counts
    @fuzzy.add(mail(OFFER), "spam")
    @fuzzy.add(mail(OFFER.sub("Dear customer", "Hello there")), "spam")

    assert_equal [ 1.0 ], @fuzzy.check(mail(OFFER)).map(&:similarity)
  end

  def test_entries_expire
    now = Time.at(1_800_000_000)
    @fuzzy.add(mail(OFFER), "spam", now:)

    refute_empty @fuzzy.check(mail(OFFER), now: now + @config.fuzzy_expiry - 1)
    assert_empty @fuzzy.check(mail(OFFER), now: now + @config.fuzzy_expiry)

    @fuzzy.add(mail(OFFER), "spam", now: now + @config.fuzzy_expiry)
    assert_equal [ 1 ], @fuzzy.check(mail(OFFER), now: now + @config.fuzzy_expiry).map(&:count)

    @database.expire(now: now + (@config.fuzzy_expiry * 2))
    assert_equal [ [ 0, 0 ] ], @database.execute("SELECT (SELECT count(*) FROM fuzzy_hashes), (SELECT count(*) FROM fuzzy_shingles)")
  end

  def test_stats_count_adds_deletes_and_matches
    @fuzzy.add(mail(OFFER), "spam")
    @fuzzy.check(mail(OFFER))
    @fuzzy.delete(mail(OFFER), "spam")

    assert_equal({ "fuzzy_adds" => 1, "fuzzy_deletes" => 1, "fuzzy_matches" => 1 },
      MailScore::Stats.new(@database).to_h.slice("fuzzy_adds", "fuzzy_deletes", "fuzzy_matches"))
  end

  def test_a_message_of_many_parts_is_looked_up_in_chunks_up_to_the_cap
    parts = (0...34_000).map { "--b\r\nContent-Type: text/plain; charset=utf-8\r\n\r\n#{it.to_s(36)}\r\n" }.join
    message = MailScore::Message.new("Subject: #{"s" * 300}\r\nContent-Type: multipart/mixed; boundary=b\r\n\r\n#{parts}--b--\r\n")

    assert_cheap(seconds: 1, objects: 1_000_000) { assert_empty @fuzzy.check(message) }
    assert_equal MailScore::Fuzzy::PART_CAP, @fuzzy.parts(message).size
    assert_match "WARN -- : fuzzy read 100 of 1000 parts", log

    many = (0...1200).map { MailScore::Fuzzy::Part.new(digest: "h#{it}", shingles: []) }
    assert_empty @fuzzy.send(:exact, many, 0)
  end

  private
    # Makes the statement matching +pattern+ fail for the block.
    def fail_on(pattern)
      @database.singleton_class.alias_method(:execute_for_real, :execute)
      @database.define_singleton_method(:execute) do |sql, *params|
        raise SQLite3::Exception, "failed" if sql.match?(pattern)
        execute_for_real(sql, *params)
      end
      yield
    ensure
      @database.singleton_class.remove_method(:execute)
    end

    def png(width, height, fill: "\0")
      "\x89PNG\r\n\x1A\n\0\0\0\rIHDR".b + [ width, height ].pack("NN") + "\x08\x02\0\0\0#{fill * 2000}".b
    end

    def mail(text, type: "text/plain", subject: "hello")
      MailScore::Message.new("Subject: #{subject}\nContent-Type: #{type}; charset=utf-8\n\n#{text}")
    end

    def part(type, body, name: nil)
      disposition = name ? "Content-Disposition: attachment; filename=\"#{name}\"\r\n" : ""
      "Content-Type: #{type}\r\nContent-Transfer-Encoding: base64\r\n#{disposition}\r\n#{[ body ].pack("m")}".b
    end

    def multipart(parts)
      "Subject: files\r\nContent-Type: multipart/mixed; boundary=b\r\n\r\n".b + parts.map { "--b\r\n".b + it + "\r\n".b }.join + "--b--\r\n".b
    end
end
