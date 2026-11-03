require "mailresolver"

module MailScore
  # The client's reverse DNS, for a caller that sent no Hostname: the first
  # name its PTR records give, taken as it is. +status+ is "found", "none"
  # without a PTR record, or "failed" when DNS gave no answer in time.
  ReverseDns = Data.define(:hostname, :status) do
    def self.lookup(address, resolver)
      new(hostname: resolver.ptr(address.to_s).first.chomp(".").downcase, status: "found")
    rescue MailResolver::NotFound
      new(hostname: nil, status: "none")
    rescue MailResolver::Error
      new(hostname: nil, status: "failed")
    end
  end
end
