require "ipaddr"

# Writes a tiny MaxMind DB, an IPv6 tree with 24-bit records, mapping each
# network to its record. Enough of the format for the reader to load it; see
# https://maxmind.github.io/MaxMind-DB/.
module MMDB
  METADATA_MARKER = "\xAB\xCD\xEFMaxMind.com".b

  class << self
    def write(path, type, networks)
      data = "".b
      root = [ nil, nil ]

      networks.each do |cidr, record|
        offset = data.bytesize
        data << encode(record)
        insert(root, IPAddr.new(cidr), offset)
      end

      nodes = flatten(root)
      tree = nodes.map { |node| node.map { record_for(it, nodes) }.map { [ it ].pack("N")[1, 3] }.join }.join
      metadata = { "node_count" => [ :uint32, nodes.size ], "record_size" => [ :uint16, 24 ], "ip_version" => [ :uint16, 6 ],
        "database_type" => type, "languages" => [ "en" ], "binary_format_major_version" => [ :uint16, 2 ],
        "binary_format_minor_version" => [ :uint16, 0 ], "build_epoch" => [ :uint64, 1_800_000_000 ], "description" => { "en" => type } }

      File.binwrite(path, tree + "\0".b * 16 + data + METADATA_MARKER + encode(metadata))
    end

    private
      # An IPv4 network sits under ::/96, where the reader looks for it.
      def insert(root, ip, offset)
        bits = ip.ipv4? ? 96 + ip.prefix : ip.prefix
        node = root
        (bits - 1).times { |i| node = (node[ip.to_i[127 - i]] ||= [ nil, nil ]) }
        node[ip.to_i[128 - bits]] = offset
      end

      def flatten(node)
        [ node, *node.grep(Array).flat_map { flatten(it) } ]
      end

      # A node's index, past the nodes for no data, or past the separator into the data.
      def record_for(child, nodes)
        case child
        when Array then nodes.index { it.equal?(child) }
        when nil then nodes.size
        else nodes.size + 16 + child
        end
      end

      def encode(value)
        case value
        in String then control(2, value.bytesize) + value.b
        in Hash then control(7, value.size) + value.map { |key, item| encode(key) + encode(item) }.join
        in [ :uint16 | :uint32 | :uint64 => type, Integer => number ] then unsigned(type, number)
        in Integer then unsigned(:uint32, value)
        in Array then control(11, value.size) + value.map { encode(it) }.join
        end
      end

      def unsigned(type, number)
        bytes = number.zero? ? "".b : [ number.to_s(16).rjust(16, "0") ].pack("H*").sub(/\A\0+/, "")
        control({ uint16: 5, uint32: 6, uint64: 9 }.fetch(type), bytes.bytesize) + bytes
      end

      # A size past 28 takes one more byte, which is all a test needs.
      def control(type, size)
        size, extra = size < 29 ? [ size, "".b ] : [ 29, [ size - 29 ].pack("C") ]
        (type < 8 ? [ (type << 5) | size ].pack("C") : [ size, type - 7 ].pack("CC")) + extra
      end
  end
end
