require "test_helper"
require "mailresolver/testing"
require "openssl"

class MailScore::Rules::DnsListsDomainsTest < MailScore::TestCase
  LISTS = [
    { "zone" => "multi.example", "symbol" => "MULTI", "weight" => 0,
      "returnbits" => { "PH_MULTI" => { "weight" => 7.5, "bit" => 8 }, "MW_MULTI" => { "weight" => 7.5, "bit" => 16 }, "MULTI_BLOCKED" => { "weight" => 0, "bit" => 1 } } },
    { "zone" => "dbl.example", "symbol" => "SPAMHAUS_DOMAIN", "weight" => 0, "no_ip" => true,
      "returncodes" => { "SPAMHAUS_DOMAIN_SPAM" => { "weight" => 6.5, "codes" => [ "127.0.1.2" ] } } }
  ].freeze

  def test_url_domains_are_asked_by_their_registrable_domain
    dns = fake("example.com.dbl.example" => { a: [ "127.0.1.2" ] })
    hits = run_rule("See https://www.Example.com/a and http://shop.example.com/b", dns:)

    assert_equal [ [ "SPAMHAUS_DOMAIN_SPAM", 6.5, "example.com" ] ], hits.map { [ it.name, it.weight, it.detail ] }
    assert_equal %w[ example.com.multi.example example.com.dbl.example ], dns.queries.map(&:first)
  end

  def test_urls_in_the_subject_are_asked_too
    dns = fake
    run_rule("http://example.com", headers: "Subject: see www.example.org now\n", dns:, lists: [ zone("checks" => %w[ urls ]) ])

    assert_equal %w[ example.com.zone.example example.org.zone.example ], dns.queries.map(&:first)
  end

  def test_a_list_may_ask_the_whole_host_of_the_first_url_of_each_domain
    dns = fake
    run_rule("https://www.example.com/a http://shop.example.com/b http://example.org", lists: [ zone("checks" => %w[ urls ], "url_full_hostname" => true) ], dns:)

    assert_equal %w[ www.example.com.zone.example example.org.zone.example ], dns.queries.map(&:first)
  end

  def test_the_senders_are_asked_by_domain_or_by_address
    dns = fake("bounce.example.org.dbl.example" => { a: [ "127.0.1.2" ] }, "example.net.dbl.example" => { a: [ "127.0.1.2" ] })
    lists = [ LISTS.last.merge("checks" => %w[ from_smtp from_mime ], "emails_domainonly" => true) ]

    assert_equal [ [ "SPAMHAUS_DOMAIN_SPAM", "bounce.example.org, example.net" ] ],
      run_rule("No links", from: "<x@Bounce.Example.org>", header_from: "a@example.net", lists:, dns:).map { [ it.name, it.detail ] }

    dns = fake
    run_rule("No links", from: "<x@Bounce.Example.org>", lists: [ zone("checks" => %w[ from_smtp ]), zone("zone" => "hashed.example", "symbol" => "HASHED", "checks" => %w[ from_smtp ], "hash" => "sha1") ], dns:)
    assert_equal [ "#{OpenSSL::Digest::SHA1.hexdigest("x@bounce.example.org")}.hashed.example" ], dns.queries.map(&:first)
  end

  def test_only_a_name_of_letters_digits_underscores_and_dashes_is_asked
    dns = fake
    lists = [ zone("checks" => %w[ helo mid ]) ]
    [ "a\\.b.example", "a\\097.example", "foo bar.example", "a\0b.example", "#{"a" * 60}.#{"b" * 60}.#{"c" * 60}.#{"d" * 60}.example" ].each do |name|
      run_rule(nil, helo: name, headers: "Message-ID: <x@#{name}>\n", lists:, dns:)
    end
    run_rule(nil, helo: "_dmarc.mx-1.example", lists:, dns:)

    assert_equal %w[ _dmarc.mx-1.example.zone.example ], dns.queries.map(&:first)
  end

  def test_the_message_id_reply_to_helo_and_host_name_domains
    dns = fake
    headers = "Message-ID: <abc@mail.example.com>\nReply-To: Sales <Sales+promo@Reply.Example.net>\n"
    run_rule("No links", headers:, helo: "mx.example.org", hostname: "client.example.info", dns:,
      lists: [ zone("checks" => %w[ mid replyto helo rdns ], "emails_domainonly" => true) ])

    assert_equal %w[ mail.example.com.zone.example mx.example.org.zone.example client.example.info.zone.example reply.example.net.zone.example ].sort,
      dns.queries.map(&:first).sort
  end

  def test_the_host_name_looked_up_is_asked_and_unknown_is_not
    dns = fake("203.0.113.9" => { ptr: [ "client.example.info" ] })
    run_rule("No links", dns:, lists: [ zone("checks" => %w[ rdns ]) ])
    assert_equal [ "client.example.info.zone.example" ], dns.queries.map(&:first) - [ "203.0.113.9" ]

    dns = fake
    run_rule("No links", hostname: "unknown", dns:, lists: [ zone("checks" => %w[ rdns ]) ])
    assert_empty dns.queries
  end

  def test_addresses_in_the_text_by_domain_or_without_their_tags
    body = "Write to John.Doe+x@gmail.com, a@shop.example.com or b@www.example.com, or <a href=\"mailto:c@example.org?subject=hi\">us</a>"
    html = "Content-Type: text/html\n"

    dns = fake
    run_rule(body, headers: html, lists: [ zone("checks" => %w[ emails ], "emails_domainonly" => true) ], dns:)
    assert_equal %w[ example.org gmail.com example.com ].map { "#{it}.zone.example" }.sort, dns.queries.map(&:first).sort

    dns = fake
    run_rule(body, headers: html, lists: [ zone("checks" => %w[ emails ]) ], dns:)
    assert_includes dns.queries.map(&:first), "johndoe.gmail.com.zone.example"
    assert_includes dns.queries.map(&:first), "a.shop.example.com.zone.example"
  end

  def test_the_domains_of_dkim_signatures_that_verify
    key = OpenSSL::PKey.generate_key("ED25519")
    raw = "From: a@example.com\r\nTo: b@example.net\r\nSubject: hi\r\n\r\nHello.\r\n"
    signed = MailAuth::Dkim.sign(raw, domain: "mail.example.com", selector: "s", key:)
    dns = fake("s._domainkey.mail.example.com" => { txt: [ "v=DKIM1; k=ed25519; p=#{[ key.raw_public_key ].pack("m0")}" ] })

    run_rule(nil, raw: signed, lists: [ zone("checks" => %w[ dkim ]), zone("zone" => "full.example", "symbol" => "FULL", "checks" => %w[ dkim ], "dkim_domainonly" => false) ], dns:)
    assert_equal %w[ example.com.zone.example mail.example.com.full.example ], dns.queries.map(&:first).grep(/zone|full/)
  end

  def test_an_international_name_is_asked_in_its_xn_form
    dns = fake("xn--e1afmkfd.xn--p1ai.zone.example" => { a: [ "127.0.0.2" ] })
    hits = run_rule("http://пример.рф/a", lists: [ zone("checks" => %w[ urls ]) ], dns:)

    assert_equal [ [ "ZONE", "пример.рф" ] ], hits.map { [ it.name, it.detail ] }
  end

  def test_an_international_name_too_long_for_the_dns_is_never_converted
    label = (0...8000).map { (0x4E00 + it).chr("UTF-8") }.join
    dns = fake

    assert_cheap(seconds: 0.5, objects: 100_000) do
      run_rule(nil, headers: "Message-ID: <a@#{label}.com>\n", lists: [ zone("checks" => %w[ mid ]) ], dns:)
      run_rule(nil, headers: "Message-ID: <a@#{"例." * 100}com>\n", lists: [ zone("checks" => %w[ mid ]) ], dns:)
    end
    assert_empty dns.queries
  end

  def test_a_hashed_list_is_asked_the_digest_of_whole_addresses
    ebl = zone("checks" => %w[ emails from_smtp ], "hash" => "sha1")
    dns = fake
    run_rule("Write to John+x@Example.com", from: "<Bounce@Example.org>", lists: [ ebl ], dns:)

    digests = %w[ john@example.com bounce@example.org ].map { "#{OpenSSL::Digest::SHA1.hexdigest(it)}.zone.example" }
    assert_equal digests, dns.queries.map(&:first)
  end

  def test_return_bits_name_the_listing_and_the_lists_weigh_at_most_their_cap
    zone = { "example.com.multi.example" => { a: [ "127.0.0.24" ] }, "example.com.dbl.example" => { a: [ "127.0.1.2" ] },
      "example.org.multi.example" => { a: [ "127.0.0.64" ] } }
    hits = run_rule("http://example.com http://example.org", dns: fake(zone))

    assert_equal [ [ "PH_MULTI", 7.5, "example.com" ], [ "MW_MULTI", 5.0, "example.com" ], [ "MULTI", 0, "example.org 127.0.0.64" ],
      [ "SPAMHAUS_DOMAIN_SPAM", 0.0, "example.com" ] ], hits.map { [ it.name, it.weight, it.detail ] }
  end

  def test_an_address_in_a_url_is_asked_by_its_reversed_octets_of_lists_that_take_addresses
    dns = fake("9.113.0.203.multi.example" => { a: [ "127.0.0.8" ] })

    assert_equal [ [ "PH_MULTI", "203.0.113.9" ] ], run_rule("http://203.0.113.9/login", dns:).map { [ it.name, it.detail ] }
    assert_equal %w[ 9.113.0.203.multi.example ], dns.queries.map(&:first)
  end

  def test_at_most_64_url_domains_are_asked_per_message_and_the_senders_besides
    dns = fake
    lists = [ zone("checks" => %w[ urls from_mime ], "emails_domainonly" => true) ]
    run_rule(Array.new(70) { "http://d#{it}x.com" }.join(" "), header_from: "a@sender.example", lists:, dns:)

    names = dns.queries.map(&:first)
    assert_equal 65, names.size
    assert_equal "d63x.com.zone.example", names[63]
    assert_equal "sender.example.zone.example", names.last
  end

  def test_links_without_text_cannot_push_a_shown_one_out
    pad = (1..64).map { %(<a href="http://pad#{it}.example/"></a>) }.join
    message = MailScore::Message.new("Content-Type: text/html\nSubject: hi\n\n#{pad}<a href=\"http://evil.example/buy\">buy</a>")
    dns = fake("evil.example.zone.example" => { a: [ "127.0.0.2" ] })
    hits = run_rule(nil, raw: message.raw, lists: [ zone("checks" => %w[ urls ]) ], dns:)

    assert_equal [ "ZONE" ], hits.map(&:name)
    assert_equal 64, dns.queries.size
  end

  def test_not_listed_fires_nothing_and_no_answer_fires_a_failure
    assert_empty run_rule("http://example.com", dns: fake)
    assert_equal [ [ "MULTI_LOOKUP_FAILED", 0.0, "example.com timeout" ], [ "SPAMHAUS_DOMAIN_LOOKUP_FAILED", 0.0, "example.com server failure" ] ],
      run_rule("http://example.com", dns: fake("example.com.multi.example" => { a: :timeout }, "example.com.dbl.example" => { a: :servfail })).map { [ it.name, it.weight, it.detail ] }
  end

  def test_a_list_skips_authenticated_senders_and_local_networks_unless_it_says_otherwise
    dns = fake("example.com.dbl.example" => { a: [ "127.0.1.2" ] })

    assert_empty run_rule("http://example.com", ip: "10.0.0.1", dns:)
    assert_empty run_rule("http://example.com", user: "alice", dns:)
    assert_empty dns.queries

    lists = [ LISTS.last.merge("exclude_users" => false, "exclude_local" => false) ]
    assert_equal [ "SPAMHAUS_DOMAIN_SPAM" ], run_rule("http://example.com", ip: "10.0.0.1", lists:, dns:).map(&:name)
    assert_equal [ "SPAMHAUS_DOMAIN_SPAM" ], run_rule("http://example.com", user: "alice", lists:, dns:).map(&:name)

    fresh = [ LISTS.last.merge("exclude_users" => true, "exclude_local" => false) ]
    assert_empty run_rule("http://example.com", user: "alice", lists: fresh, dns:)
    assert_equal [ "SPAMHAUS_DOMAIN_SPAM" ], run_rule("http://example.com", ip: "10.0.0.1", lists: fresh, dns:).map(&:name)
  end

  def test_past_the_budget_nothing_is_asked
    dns = fake("example.com.dbl.example" => { a: [ "127.0.1.2" ] })

    assert_empty run_rule("http://example.com", dns:, deadline: MailScore::Envelope.now - 1)
    assert_empty dns.queries
  end

  def test_off_by_default
    dns = fake

    assert_empty run_rule("http://example.com", lists: [], dns:)
    assert_empty dns.queries
  end

  private
    def fake(zone = {})
      MailResolver::Testing::FakeResolver.new(zone)
    end

    def zone(settings)
      { "zone" => "zone.example", "symbol" => "ZONE", "weight" => 1 }.merge(settings)
    end

    def run_rule(body, ip: "203.0.113.9", user: nil, from: nil, header_from: nil, headers: "", helo: nil, hostname: nil, raw: nil,
      lists: LISTS, dns: fake, deadline: nil)
      config = MailScore::Config.parse(SETTINGS.merge("uribl" => lists), env: TOKENS)
      message = MailScore::Message.new(raw || "#{"From: #{header_from}\n" if header_from}#{headers}Subject: hi\n\n#{body}")
      env = { "HTTP_IP" => ip, "HTTP_USER" => user, "HTTP_FROM" => from, "HTTP_HELO" => helo, "HTTP_HOSTNAME" => hostname }.compact
      envelope = MailScore::Envelope.read(env, message, local_networks: config.local_networks)
      MailScore::Rules::DnsLists.new(config, nil, dns:).run(message, envelope.with(deadline:))
    end
end
