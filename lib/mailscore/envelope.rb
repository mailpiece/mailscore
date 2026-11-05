require "ipaddr"

module MailScore
  # The SMTP session as the caller saw it, from the /check request headers.
  # +from+ is the envelope sender without angle brackets, "" for a null
  # sender; +recipients+ is a list. Without a From or Rcpt header, they come
  # from the message's own From and To. +mail_from+ is the caller's sender
  # alone, nil without a From header. +local_networks+ are the config's.
  # +deadline+ is the scan's, on the monotonic clock, and +lookups+ keeps
  # what the scan looked up once for all its rules; the scanner sets both.
  # +reverse_dns_status+ is the caller's lookup outcome, nil when absent or
  # not one of REVERSE_DNS_STATUSES. +unconfirmed_hostname+ is the name a
  # PTR gave that did not resolve back, lowercased, nil unless a full host
  # name: a rule may only add weight for it, never trust it.
  Envelope = Data.define(:ip, :helo, :hostname, :from, :mail_from, :recipients, :deliver_to, :user, :tls_version, :tls_cipher,
    :queue_id, :local_networks, :deadline, :lookups, :reverse_dns_status, :unconfirmed_hostname) do
    REVERSE_DNS_STATUSES = %w[ confirmed unconfirmed none temporary_failure ].freeze

    def self.read(env, message, local_networks: [])
      header = ->(name) { header(env, name) }
      mail_from = header["FROM"]&.then { unbracketed(it) }

      new \
        ip: header["IP"],
        helo: header["HELO"],
        hostname: header["HOSTNAME"],
        reverse_dns_status: header["REVERSE_DNS_STATUS"]&.downcase&.then { it if REVERSE_DNS_STATUSES.include?(it) },
        unconfirmed_hostname: header["UNCONFIRMED_HOSTNAME"]&.chomp(".")&.downcase&.then { it if it.match?(Rules::HeloNotFqdn::FQDN) },
        from: mail_from || message.from_addresses.first,
        mail_from:,
        recipients: recipients(header["RCPT"]) || message.to_addresses,
        deliver_to: header["DELIVER_TO"]&.then { unbracketed(it) },
        user: header["USER"],
        tls_version: header["TLS_VERSION"],
        tls_cipher: header["TLS_CIPHER"],
        queue_id: header["QUEUE_ID"],
        local_networks:,
        deadline: nil
    end

    def initialize(lookups: {}, reverse_dns_status: nil, unconfirmed_hostname: nil, **)
      super
    end

    # A request header as UTF-8 with invalid bytes replaced, stripped, or
    # nil when absent or blank, so no rule meets a byte it can't read.
    def self.header(env, name)
      env["HTTP_#{name}"].to_s.dup.force_encoding(Encoding::UTF_8).scrub.strip.then { it unless it.empty? }
    end

    # Repeated Rcpt headers arrive joined with commas.
    def self.recipients(value)
      value.to_s.split(",").map { unbracketed(it.strip) }.reject(&:empty?).then { it unless it.empty? }
    end

    def self.unbracketed(address)
      address.delete_prefix("<").delete_suffix(">")
    end

    def self.now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def null_sender?
      from == ""
    end

    # An authenticated sender, or a client in the local networks.
    def trusted?
      !user.to_s.empty? || local?
    end

    def local?
      local_networks.any? { it.include?(address) }
    end

    # The client's reverse DNS, looked up once per scan when the caller sent
    # no Hostname, or only the address in brackets. Failed, with no lookup,
    # when the caller's own lookup failed. nil for a trusted sender or
    # without a client IP.
    def reverse_dns(resolver)
      return if !address || trusted?
      return ReverseDns.new(hostname: nil, status: "failed") if reverse_dns_status == "temporary_failure"
      return if hostname && !hostname.start_with?("[")
      lookups.fetch(:reverse_dns) { lookups[:reverse_dns] = ReverseDns.lookup(address, resolver) }
    end

    # The client's host name: the caller's, or the one reverse DNS gave.
    def client_hostname(resolver)
      hostname.to_s.start_with?("[") || hostname.nil? ? reverse_dns(resolver)&.hostname : hostname
    end

    # The client IP, nil when absent or unreadable.
    def address
      IPAddr.new(ip.to_s).native
    rescue IPAddr::Error
      nil
    end

    # Seconds left in the scan's budget, never below zero. A rule that waits
    # on the network caps its timeouts by it.
    def remaining
      deadline ? [ deadline - Envelope.now, 0 ].max : Float::INFINITY
    end
  end
end
