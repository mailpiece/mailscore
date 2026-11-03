require "test_helper"
require "mailresolver/testing"

class MailScore::ResolverTest < MailScore::TestCase
  MESSAGE = MailScore::Message.new("Subject: hi\n\nbody")

  def setup
    @dns = MailResolver::Testing::FakeResolver.new("example.com" => { txt: [ "v=spf1 -all" ], mx: :servfail })
  end

  def test_a_lookup_within_the_budget_asks_dns
    resolver = resolver_with(MailScore::Envelope.now + 5)

    assert_equal [ "v=spf1 -all" ], resolver.txt("example.com")
    assert_raises(MailResolver::ServerFailure) { resolver.mx("example.com") }
  end

  def test_past_the_budget_a_lookup_times_out_without_asking
    assert_raises(MailResolver::Timeout) { resolver_with(MailScore::Envelope.now - 1).txt("example.com") }
    assert_empty @dns.queries
  end

  def test_a_budget_too_short_to_scale_times_out_without_building_a_resolver
    envelope = Struct.new(:remaining).new(Float::MIN * Float::EPSILON)

    assert_raises(MailResolver::Timeout) { MailScore::Resolver.new(envelope).txt("example.com") }
  end

  private
    def resolver_with(deadline)
      MailScore::Resolver.new(MailScore::Envelope.read({}, MESSAGE).with(deadline:), dns: @dns)
    end
end
