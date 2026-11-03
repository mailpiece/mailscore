require "test_helper"
require "mailresolver/testing"
require "openssl"

class MailScore::Rules::AuthenticationTest < MailScore::TestCase
  KEY = OpenSSL::PKey.generate_key("ED25519")
  KEY_RECORD = "v=DKIM1; k=ed25519; p=#{[ KEY.raw_public_key ].pack("m0")}".freeze

  RAW = <<~MAIL.gsub("\n", "\r\n").freeze
    From: Alice <alice@example.com>
    To: bob@example.net
    Subject: Hello
    Date: Tue, 03 Nov 2026 10:00:00 +0000
    Message-ID: <1@example.com>

    Hi Bob.
  MAIL

  ZONE = {
    "example.com" => { txt: [ "v=spf1 ip4:192.0.2.1 ~all" ] },
    "mail._domainkey.example.com" => { txt: [ KEY_RECORD ] },
    "_dmarc.example.com" => { txt: [ "v=DMARC1; p=reject" ] }
  }.freeze

  Dice = Data.define(:roll) do
    def rand(_)
      roll
    end
  end

  def test_spf_by_status
    assert_hit "SPF_PASS", -0.2, "example.com v=spf1 ip4:192.0.2.1 ~all", ip: "192.0.2.1"
    assert_hit "SPF_SOFTFAIL", 0.0, "example.com v=spf1 ip4:192.0.2.1 ~all", ip: "198.51.100.7"
    assert_hit "SPF_FAIL", 1.0, "example.com v=spf1 -all", ip: "198.51.100.7", zone: ZONE.merge("example.com" => { txt: [ "v=spf1 -all" ] })
    assert_hit "SPF_NONE", 0.0, "example.com", ip: "192.0.2.1", zone: ZONE.merge("example.com" => { a: [ "192.0.2.1" ] })
    assert_hit "SPF_LOOKUP_FAILED", 0.0, "example.com", ip: "192.0.2.1", zone: ZONE.merge("example.com" => { txt: :timeout })
    assert_hit "SPF_INVALID", 0.0, "example.com v=spf1 bogus -all", ip: "192.0.2.1", zone: ZONE.merge("example.com" => { txt: [ "v=spf1 bogus -all" ] })
  end

  def test_a_record_that_lets_anyone_send
    plus_all = ZONE.merge("example.com" => { txt: [ "v=spf1 +all" ] })

    assert_hit "SPF_ALLOWS_ANYONE", 4.0, "example.com v=spf1 +all", ip: "198.51.100.7", zone: plus_all
    assert_hit "SPF_ALLOWS_ANYONE", 4.0, "example.com v=spf1 ip4:192.0.2.1 all", ip: "2001:db8::7", zone: ZONE.merge("example.com" => { txt: [ "v=spf1 ip4:192.0.2.1 all" ] })
    assert_hit "DMARC_PASS", -0.5, "example.com", ip: "198.51.100.7", zone: plus_all
    refute_includes run_rule(ip: "198.51.100.7", zone: plus_all).map(&:name), "SPF_PASS"
    assert_hit "SPF_PASS", -0.2, "example.com v=spf1 ip4:192.0.2.1 -all", ip: "192.0.2.1", zone: ZONE.merge("example.com" => { txt: [ "v=spf1 ip4:192.0.2.1 -all" ] })
  end

  def test_an_include_that_lets_anyone_send
    zone = ZONE.merge("example.com" => { txt: [ "v=spf1 ip4:192.0.2.1 include:esp.example.net -all" ] },
      "esp.example.net" => { txt: [ "v=spf1 +all" ] })

    assert_hit "SPF_ALLOWS_ANYONE", 4.0, "example.com v=spf1 ip4:192.0.2.1 include:esp.example.net -all", zone:, ip: "198.51.100.7"
    assert_hit "DMARC_PASS", -0.5, "example.com", zone:, ip: "198.51.100.7"
  end

  def test_spf_is_checked_once
    dns = MailResolver::Testing::FakeResolver.new(ZONE.merge("example.com" => { txt: [ "v=spf1 +all" ] }))
    run_rule(ip: "198.51.100.7", dns:)

    assert_equal 1, dns.queries.count([ "example.com", :txt ])
  end

  def test_spf_checks_the_callers_sender_not_the_message_from
    assert_hit "SPF_NONE", 0.0, "bounces.example.org", ip: "192.0.2.1", from: "<x@bounces.example.org>"
    assert_hit "DMARC_FAIL_REJECT_POLICY", 5.5, "example.com p=reject", ip: "192.0.2.1", from: "x@bounces.example.org"
  end

  def test_a_null_sender_checks_the_helo_identity
    zone = ZONE.merge("mx.example.com" => { txt: [ "v=spf1 ip4:192.0.2.1 -all" ] })

    assert_hit "SPF_PASS", -0.2, "mx.example.com v=spf1 ip4:192.0.2.1 -all", ip: "192.0.2.1", zone:, from: "<>"
    assert_hit "SPF_FAIL", 1.0, "mx.example.com v=spf1 ip4:192.0.2.1 -all", ip: "198.51.100.7", zone:, from: "<>"
    assert_hit "DMARC_PASS", -0.5, "example.com", ip: "192.0.2.1", zone:, from: "<>"
  end

  def test_without_a_from_header_spf_and_dmarc_are_skipped
    assert_equal %w[ DKIM_NONE ARC_NONE ], run_rule(ip: "192.0.2.1", from: nil).map(&:name)
  end

  def test_a_trusted_sender_skips_spf_dkim_and_dmarc_but_not_arc
    names = run_rule(raw: MailAuth::Arc.seal(signed, authentication_results: "mx.example.com; dkim=pass", chain_status: "none",
      domain: "example.com", selector: "mail", key: KEY), ip: "192.0.2.1", user: "alice").map(&:name)

    assert_equal %w[ ARC_PASS ], names
    assert_equal %w[ ARC_NONE ], run_rule(raw: signed, ip: "10.1.2.3", local_networks: [ IPAddr.new("10.0.0.0/8") ]).map(&:name)
  end

  def test_without_an_ip_spf_and_dmarc_are_skipped
    names = run_rule.map(&:name)

    assert_equal %w[ DKIM_NONE ARC_NONE ], names
    assert_equal names, run_rule(ip: "not an address").map(&:name)
  end

  def test_dkim_by_status
    assert_hit "DKIM_PASS", -0.1, "example.com", raw: signed
    assert_hit "DKIM_FAIL", 1.0, "example.com", raw: signed.sub("Hi Bob.", "Hi Eve.")
    assert_hit "DKIM_LOOKUP_FAILED", 0.0, "example.com", raw: signed, zone: ZONE.merge("mail._domainkey.example.com" => { txt: :servfail })
    assert_hit "DKIM_NONE", 0.0, nil
  end

  def test_a_signer_that_is_not_a_host_name_is_left_out
    raw = MailAuth::Dkim.sign(RAW, domain: "gmail.com, x.example.com", selector: "mail", key: KEY)
    zone = ZONE.merge("mail._domainkey.gmail.com, x.example.com" => { txt: [ KEY_RECORD ] })
    hit = run_rule(raw:, zone:).find { it.name.start_with?("DKIM_") }

    assert_equal [ "DKIM_INVALID", nil, [] ], [ hit.name, hit.detail, hit.data ]

    hit = run_rule(raw: signed).find { it.name.start_with?("DKIM_") }
    assert_equal [ "DKIM_PASS", "example.com", [ "example.com" ] ], [ hit.name, hit.detail, hit.data ]
  end

  def test_a_signature_over_part_of_the_body_earns_no_credit
    partial = MailAuth::DkimResult.new(signatures: [ MailAuth::Signature.new(status: "pass", domain: "example.com", aligned: true, under_sized: 40) ])
    hits = run_rule(ip: "198.51.100.7", dkim: partial)

    assert_equal [ [ "DKIM_PARTIAL_BODY", 0.5, "example.com", nil ], [ "DMARC_FAIL_REJECT_POLICY", "example.com p=reject" ] ],
      hits.select { it.name.start_with?("DKIM_", "DMARC_") }.map { it.name.start_with?("DKIM_") ? [ it.name, it.weight, it.detail, it.data ] : [ it.name, it.detail ] }
  end

  def test_dmarc_passes_on_an_aligned_signature_or_spf
    assert_hit "DMARC_PASS", -0.5, "example.com", raw: signed, ip: "198.51.100.7"
    assert_hit "DMARC_PASS", -0.5, "example.com", ip: "192.0.2.1"
  end

  def test_a_dmarc_failure_weighs_by_policy
    assert_hit "DMARC_FAIL_REJECT_POLICY", 5.5, "example.com p=reject", ip: "198.51.100.7"
    assert_hit "DMARC_FAIL_QUARANTINE_POLICY", 4.0, "example.com p=quarantine", ip: "198.51.100.7", zone: dmarc("p=quarantine")
    assert_hit "DMARC_FAIL_NONE_POLICY", 0.1, "example.com p=none", ip: "198.51.100.7", zone: dmarc("p=none")
  end

  def test_a_p_reject_failure_outweighs_every_credit_a_spoof_can_earn_for_itself
    symbols = MailScore::Rules::Authentication::SYMBOLS
    credits = symbols.values_at("SPF_PASS", "DKIM_PASS", "ARC_PASS").sum(&:first) + MailScore::Rules::Bounce::WEIGHT

    assert_operator symbols.fetch("DMARC_FAIL_REJECT_POLICY").first + credits, :>=, MailScore::Config::ACTIONS["greylist"]
  end

  def test_out_of_the_pct_sample_reject_counts_as_quarantine
    zone = dmarc("p=reject; pct=50")

    assert_hit "DMARC_FAIL_REJECT_POLICY", 5.5, "example.com p=reject", ip: "198.51.100.7", zone:, random: Dice.new(10)
    assert_hit "DMARC_FAIL_QUARANTINE_POLICY", 4.0, "example.com p=reject pct=50", ip: "198.51.100.7", zone:, random: Dice.new(70)
    assert_hit "DMARC_FAIL_NONE_POLICY", 0.1, "example.com p=quarantine pct=50", ip: "198.51.100.7", zone: dmarc("p=quarantine; pct=50"), random: Dice.new(70)
  end

  def test_a_from_with_no_single_domain_is_invalid_in_dmarcs_place
    [ "From: \"alice@example.com\" <alice>", "From: Undisclosed" ].each do |from|
      hits = run_rule(raw: RAW.sub("From: Alice <alice@example.com>", from), ip: "198.51.100.7")

      assert_equal [ [ "FROM_UNREADABLE", 7.5 ] ], hits.select { it.name.start_with?("DMARC", "FROM") }.map { [ it.name, it.weight ] }, from
    end

    [ "From: a@example.com, b@example.org", "From: a@example.com\r\nFrom: b@example.org", "From: " ].each do |from|
      refute_includes run_rule(raw: RAW.sub("From: Alice <alice@example.com>", from), ip: "198.51.100.7").map(&:name), "FROM_UNREADABLE", from
    end
    refute_includes run_rule(raw: RAW.sub("From: Alice <alice@example.com>", "From: Undisclosed")).map(&:name), "FROM_UNREADABLE"

    # A comment does not hide the domain beside it.
    assert_hit "DMARC_FAIL_REJECT_POLICY", 5.5, "example.com p=reject", raw: RAW.sub("From: Alice <alice@example.com>", "From: alice@(x)example.com"), ip: "198.51.100.7"
  end

  def test_dmarc_without_a_record_or_an_answer
    assert_hit "DMARC_NONE", 0.0, "example.com", ip: "192.0.2.1", zone: ZONE.except("_dmarc.example.com")
    assert_hit "DMARC_LOOKUP_FAILED", 0.0, "example.com", ip: "192.0.2.1", zone: ZONE.merge("_dmarc.example.com" => { txt: :timeout })
  end

  def test_arc_by_status
    assert_hit "ARC_PASS", -1.0, "example.com", raw: sealed
    assert_hit "ARC_FAIL", 1.0, "ARC-Message-Signature i=1 did not verify", raw: sealed.sub("Hi Bob.", "Hi Eve.")
    assert_hit "ARC_NONE", 0.0, nil
  end

  def test_a_malformed_arc_chain_is_invalid
    hit = arc_hit(sealed.sub(/^ARC-Authentication-Results:.*\r\n/, ""))

    assert_equal [ "ARC_INVALID", 0.5 ], [ hit.name, hit.weight ]
    assert_match(/i=1/, hit.detail)
    assert_equal "ARC_INVALID", arc_hit(sealed.sub("cv=none", "cv=pass")).name
  end

  def test_a_hop_that_saw_the_chain_broken_rejects_it
    resealed = MailAuth::Arc.seal(sealed, authentication_results: "relay.example.com; arc=fail", chain_status: "fail",
      domain: "example.com", selector: "mail", key: KEY)

    assert_equal [ "ARC_FAIL", 1.0 ], arc_hit(resealed).then { [ it.name, it.weight ] }
  end

  def test_an_arc_key_that_cannot_be_fetched_rejects_the_chain
    hit = arc_hit(sealed, zone: ZONE.merge("mail._domainkey.example.com" => { txt: :timeout }))

    assert_equal [ "ARC_FAIL", 1.0 ], [ hit.name, hit.weight ]
  end

  def test_no_lookup_starts_past_the_budget
    dns = MailResolver::Testing::FakeResolver.new(ZONE)
    hits = run_rule(raw: signed, ip: "192.0.2.1", dns:, deadline: MailScore::Envelope.now - 1)

    assert_equal %w[ SPF_LOOKUP_FAILED DKIM_LOOKUP_FAILED DMARC_LOOKUP_FAILED ARC_NONE ], hits.map(&:name)
    assert_empty dns.queries
  end

  def test_the_catalogue_lists_every_symbol
    names = MailScore::Rules.catalogue([ MailScore::Rules::Authentication ]).map { it[:name] }

    assert_includes names, "DMARC_FAIL_REJECT_POLICY"
    refute_includes names, "ARC_LOOKUP_FAILED"
    assert_equal MailScore::Rules::Authentication::SYMBOLS.size, names.size
  end

  private
    def run_rule(raw: RAW, ip: nil, from: "alice@example.com", user: nil, local_networks: [], zone: ZONE,
      dns: MailResolver::Testing::FakeResolver.new(zone), random: Random, deadline: nil, dkim: nil)
      message = MailScore::Message.new(raw)
      env = { "HTTP_IP" => ip, "HTTP_HELO" => "mx.example.com", "HTTP_FROM" => from, "HTTP_USER" => user }.compact
      envelope = MailScore::Envelope.read(env, message, local_networks:).with(deadline:, lookups: { dkim: }.compact)
      MailScore::Rules::Authentication.new(nil, nil, dns:, random:).run(message, envelope)
    end

    def assert_hit(name, weight, detail, **options)
      hit = run_rule(**options).find { it.name.start_with?(name[/\A[A-Z]+_/]) }

      assert_equal [ name, weight, detail ], [ hit&.name, hit&.weight, hit&.detail ]
    end

    def arc_hit(raw, **options)
      run_rule(raw:, **options).find { it.name.start_with?("ARC_") }
    end

    def dmarc(policy)
      ZONE.merge("_dmarc.example.com" => { txt: [ "v=DMARC1; #{policy}" ] })
    end

    def signed
      MailAuth::Dkim.sign(RAW, domain: "example.com", selector: "mail", key: KEY)
    end

    def sealed
      MailAuth::Arc.seal(RAW, authentication_results: "mx.example.com; spf=pass smtp.mailfrom=example.com",
        chain_status: "none", domain: "example.com", selector: "mail", key: KEY)
    end
end
