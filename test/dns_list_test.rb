require "test_helper"

class MailScore::DnsListTest < MailScore::TestCase
  ZEN = { "zone" => "Zen.Example.", "symbol" => "ZEN", "weight" => 0,
    "returncodes" => { "ZEN_SBL" => { "weight" => 4.0, "codes" => [ "127.0.0.2" ] }, "ZEN_XBL" => { "weight" => 4.0, "codes" => "127.0.0.4" } } }.freeze

  def test_no_list_is_asked_by_default
    config = parse(SETTINGS)

    assert_empty config.dnsbl
    assert_empty config.uribl
  end

  def test_recommended_asks_the_bundled_lists
    config = parse(SETTINGS.merge("dnsbl" => "recommended", "uribl" => "recommended"))

    assert_equal %w[ zen.spamhaus.org rep.mailspike.net list.dnswl.org dwl.dnswl.org bl.spameatingmonkey.net bl.ipv6.spameatingmonkey.net
      bip.virusfree.cz bl.blocklist.de ], config.dnsbl.map(&:zone)
    assert_equal %w[ ebl.msbl.org email.rspamd.com multi.surbl.org multi.uribl.com uribl.rspamd.com dbl.spamhaus.org
      uribl.spameatingmonkey.net fresh15.spameatingmonkey.net ], config.uribl.map(&:zone)
    assert_equal({ "CLIENT" => 4.0, "RECEIVED" => 3.0 }, config.dnsbl.first.returns.first.weight)
  end

  def test_a_list_of_your_own_is_asked_alone
    config = parse(SETTINGS.merge("dnsbl" => [ ZEN ], "uribl" => "recommended"))

    assert_equal [ "zen.example" ], config.dnsbl.map(&:zone)
    assert_equal 8, config.uribl.size
  end

  def test_a_list_parses
    list = parse(SETTINGS.merge("dnsbl" => [ ZEN.merge("ipv6" => false) ])).dnsbl.first

    assert_equal [ "zen.example", "ZEN", 0, true, false ], [ list.zone, list.symbol, list.weight, list.ipv4, list.ipv6 ]
    assert_equal [ [ "ZEN_SBL", 4.0, [ "127.0.0.2" ], nil ], [ "ZEN_XBL", 4.0, [ "127.0.0.4" ], nil ] ], list.returns.map { [ it.symbol, it.weight, it.codes, it.bit ] }
    assert_equal({ "ZEN" => [ 0, "Listed in zen.example" ], "ZEN_SBL" => [ 4.0, "Listed in zen.example as 127.0.0.2" ],
      "ZEN_XBL" => [ 4.0, "Listed in zen.example as 127.0.0.4" ], "ZEN_LOOKUP_FAILED" => [ 0.0, "Lookup in zen.example failed" ] }, list.symbols)
  end

  def test_a_malformed_list_fails
    [ ZEN.except("symbol"), ZEN.merge("symbol" => "zen"), ZEN.merge("weight" => "high"), ZEN.merge("zone" => ""), ZEN.merge("ipv6" => "no"),
      ZEN.merge("checks" => [ "bogus" ]), ZEN.merge("checks" => []), ZEN.merge("requests_limit" => 0), ZEN.merge("returncodes" => { "ZEN_SBL" => { "weight" => 4 } }),
      ZEN.merge("returncodes" => { "ZEN_SBL" => { "weight" => 4, "codes" => [ "spam" ] } }),
      ZEN.merge("returnbits" => { "ZEN_SBL" => { "weight" => 4, "bit" => 0 } }),
      ZEN.merge("returncodes" => { "ZEN_LOOKUP_FAILED" => { "weight" => 4, "codes" => [ "127.0.0.2" ] } }),
      ZEN.merge("returncodes" => { "ZEN_SBL" => { "weight" => 4, "codes" => [ "127%.0%.0%.%q" ] } }),
      ZEN.merge("returncodes" => { "ZEN_SBL" => { "weight" => 4, "codes" => [ "127%.0%.[0-9" ] } }),
      ZEN.merge("whitelist_exception" => "ZEN_SBL"), ZEN.merge("is_whitelist" => "yes") ].each do |list|
      assert_raises(MailScore::ConfigError, list.inspect) { parse(SETTINGS.merge("dnsbl" => [ list ])) }
    end
    [ ZEN, "Recommended", "spamhaus" ].each do |lists|
      assert_raises(MailScore::ConfigError, lists.inspect) { parse(SETTINGS.merge("dnsbl" => lists)) }
    end
  end

  def test_an_answer_fires_returns_by_code_or_by_bit
    bits = { "zone" => "multi.example", "symbol" => "MULTI", "weight" => 0,
      "returnbits" => { "MULTI_PH" => { "weight" => 7.5, "bit" => 8 }, "MULTI_MW" => { "weight" => 7.5, "bit" => 16 } } }

    assert_equal [ [ "ZEN_SBL", "203.0.113.9" ] ], fired(ZEN, "127.0.0.2")
    assert_equal [ [ "ZEN", "203.0.113.9 127.0.0.99" ] ], fired(ZEN, "127.0.0.99")
    assert_empty fired(ZEN.merge("unknown" => false), "127.0.0.99")
    assert_equal [ [ "MULTI_PH", "203.0.113.9" ], [ "MULTI_MW", "203.0.113.9" ] ], fired(bits, "127.0.0.24")
    assert_equal [ [ "MULTI", "203.0.113.9 127.0.0.2" ] ], fired(bits, "127.0.0.2")
    assert_equal [ [ "PLAIN", "203.0.113.9" ] ], fired({ "zone" => "plain.example", "symbol" => "PLAIN", "weight" => 1, "unknown" => false }, "127.0.0.2")
  end

  def test_codes_with_a_percent_or_a_bracket_are_patterns
    dnswl = { "zone" => "list.example", "symbol" => "WL", "weight" => 0, "returncodes" => {
      "WL_LOW" => { "weight" => -0.1, "codes" => [ "127%.0%.%d%.1", "127%.0%.[02-9]%d%.1", "127%.0%.1[1-9]%.1", "127%.0%.[12]%d%d%.1" ] },
      "WL_BLOCKED" => { "weight" => 0, "codes" => [ "127%.0%.0%.255", "127%.0%.10%.%d+" ] },
      "WL_EXACT" => { "weight" => 0, "codes" => [ "127.0.0.2" ] } } }

    assert_equal [ "WL_LOW" ], fired(dnswl, "127.0.5.1").map(&:first)
    assert_equal [ "WL_LOW" ], fired(dnswl, "127.0.15.1").map(&:first)
    assert_equal [ "WL_LOW" ], fired(dnswl, "127.0.205.1").map(&:first)
    assert_equal [ "WL" ], fired(dnswl, "127.0.1.7").map(&:first)
    assert_equal [ "WL_BLOCKED" ], fired(dnswl, "127.0.10.42").map(&:first)
    assert_equal [ "WL_EXACT" ], fired(dnswl, "127.0.0.2").map(&:first)
    assert_equal [ "WL_EXACT" ], fired(dnswl, "127x0x0x2").map(&:first)
    assert_equal "Listed in list.example as 127%.0%.0%.255, 127%.0%.10%.%d+", list(dnswl).symbols["WL_BLOCKED"].last
  end

  def test_a_hashed_list_is_asked_a_digest
    sha1 = list(ZEN.merge("hash" => "sha1"))
    md5 = list(ZEN.merge("hash" => "md5", "hash_len" => 32))
    blake2 = list(ZEN.merge("hash" => "blake2", "hash_format" => "base32", "hash_len" => 32))

    assert_equal OpenSSL::Digest::SHA1.hexdigest("a@example.com"), sha1.hashed("a@example.com")
    assert_equal OpenSSL::Digest::MD5.hexdigest("example.com/path"), md5.hashed("example.com/path")
    assert_equal 32, blake2.hashed("example.com").size
    assert_equal "a@example.com", list(ZEN).hashed("a@example.com")
    assert_equal "@", sha1.delimiter
    assert_equal ".", list(ZEN).delimiter
  end

  def test_z_base_32_takes_each_bytes_low_bits_first
    assert_equal "yy", MailScore::DnsList.zbase32("\x00".b)
    assert_equal "98", MailScore::DnsList.zbase32("\xff".b)
    assert_equal "99999999", MailScore::DnsList.zbase32("\xff\xff\xff\xff\xff".b)
  end

  def test_an_address_is_reversed_by_octets_or_nibbles
    assert_equal "9.113.0.203", MailScore::DnsList.reversed(IPAddr.new("203.0.113.9"))
    assert_equal "1.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.8.b.d.0.1.0.0.2", MailScore::DnsList.reversed(IPAddr.new("2001:db8::1"))
  end

  private
    def parse(settings)
      MailScore::Config.parse(settings, env: TOKENS)
    end

    def fired(settings, answer)
      list = list(settings)
      list.fired(list.queries([ [ "203.0.113.9", "from", "9.113.0.203" ] ], []).first, answer).map { [ it.symbol, it.detail ] }
    end

    def list(settings)
      parse(SETTINGS.merge("dnsbl" => [ settings ])).dnsbl.first
    end
end
