require "test_helper"
require "mailresolver/testing"

class MailScore::Rules::GenericHostnameTest < MailScore::TestCase
  def test_a_dynamic_host_name
    hit = run_rule(hostname: "203-0-113-9.dynamic.example.net")

    assert_equal [ "HOSTNAME_GENERIC_VERY_HIGH", 0.0, "203-0-113-9.dynamic.example.net" ], [ hit.name, hit.weight, hit.detail ]
    assert_equal "HOSTNAME_GENERIC_HIGH", run_rule(hostname: "a.dsl-line-9.example.net").name
    assert_equal "HOSTNAME_GENERIC_MEDIUM", run_rule(hostname: "cable-9.example.net").name
    assert_equal "HOSTNAME_GENERIC_LOW", run_rule(hostname: "host-9.example.net").name
    assert_equal "HOSTNAME_GENERIC_VERY_LOW", run_rule(hostname: "srv.vps.example.net").name
  end

  def test_a_name_looked_up_by_mailscore
    assert_equal "198-51-100-7.pool.example.net", run_rule(ip: "198.51.100.7", hostname: nil).detail
  end

  def test_a_dynamic_or_private_helo
    assert_equal [ "HELO_GENERIC_VERY_HIGH", "ppp-9.example.net" ], run_rule(helo: "ppp-9.example.net").then { [ it.name, it.detail ] }
    assert_equal "HELO_GENERIC_VERY_HIGH", run_rule(helo: "speedtouch.lan").name
    assert_equal "HELO_GENERIC_VERY_HIGH", run_rule(helo: "office.localdomain").name
  end

  def test_only_the_likelier_fires_the_helo_on_a_tie
    assert_equal "HOSTNAME_GENERIC_VERY_HIGH", run_rule(helo: "host-9.example.net", hostname: "dhcp-9.example.net").name
    assert_equal "HELO_GENERIC_HIGH", run_rule(helo: "pool-9.example.net", hostname: "dsl-9.example.net").name
    assert_equal "HELO_GENERIC_LOW", run_rule(helo: "host-9.example.net", hostname: "mx.example.net").name
  end

  def test_a_mail_server_name_an_address_or_unknown
    assert_nil run_rule(helo: "mx.example.com", hostname: "mx.example.com")
    assert_nil run_rule(helo: "[203.0.113.9]", hostname: "unknown")
    assert_nil run_rule(helo: "203-0-113-9")
    assert_nil run_rule(helo: "COMPUTER")
  end

  def test_a_trusted_sender_is_not_checked
    assert_nil run_rule(hostname: "dhcp-9.example.net", user: "alice")
  end

  private
    def run_rule(ip: "203.0.113.9", helo: nil, hostname: "mx.example.com", user: nil)
      message = MailScore::Message.new("Subject: hi\n\nbody")
      env = { "HTTP_IP" => ip, "HTTP_HELO" => helo, "HTTP_HOSTNAME" => hostname, "HTTP_USER" => user }.compact
      dns = MailResolver::Testing::FakeResolver.new("198.51.100.7" => { ptr: [ "198-51-100-7.pool.example.net" ] })
      MailScore::Rules::GenericHostname.new(nil, nil, dns:).run(message, MailScore::Envelope.read(env, message))
    end
end
