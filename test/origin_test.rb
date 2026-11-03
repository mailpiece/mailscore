require "test_helper"
require_relative "support/mmdb"

class MailScore::OriginTest < MailScore::TestCase
  def setup
    dir = Dir.mktmpdir
    @asn = File.join(dir, "GeoLite2-ASN.mmdb")
    @country = File.join(dir, "GeoLite2-Country.mmdb")
    MMDB.write(@asn, "GeoLite2-ASN", "203.0.113.0/24" => { "autonomous_system_number" => 64500, "autonomous_system_organization" => "Example" },
      "2001:db8::/32" => { "autonomous_system_number" => 64501 })
    MMDB.write(@country, "GeoLite2-Country", "203.0.113.0/24" => { "country" => { "iso_code" => "DE" }, "registered_country" => { "iso_code" => "NL" } })
  end

  def test_the_asn_is_read_from_its_file
    origin = MailScore::Origin.new(asn_database: @asn)

    assert_equal "AS64500", origin.asn(IPAddr.new("203.0.113.9"))
    assert_equal "AS64501", origin.asn(IPAddr.new("2001:db8:1::1"))
    assert_nil origin.asn(IPAddr.new("192.0.2.1"))
  end

  def test_the_country_is_where_the_network_is_registered
    origin = MailScore::Origin.new(country_database: @country)

    assert_equal "NL", origin.country(IPAddr.new("203.0.113.9"))
    assert_nil origin.country(IPAddr.new("2001:db8:1::1"))
  end

  def test_without_its_file_there_is_no_answer
    origin = MailScore::Origin.new(country_database: @country)

    assert_nil origin.asn(IPAddr.new("203.0.113.9"))
  end

  def test_each_file_is_opened_once
    origin = MailScore::Origin.new(asn_database: @asn)
    origin.asn(IPAddr.new("203.0.113.9"))
    File.delete(@asn)

    assert_equal "AS64500", origin.asn(IPAddr.new("203.0.113.9"))
  end
end
