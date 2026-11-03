require "test_helper"

class MailScore::DnsListReceivedTest < MailScore::TestCase
  CASES = {
    "from smtp11.mailtrack.pl (smtp11.mailtrack.pl [185.243.30.90])" => "185.243.30.90",
    "from server.example.nl (unknown [IPv6:2a01:7c8:aab6:26d:5054:ff:fed1:1da2])\n\t(using TLSv1.2)\n\tby mx1.example.org (Postfix) with ESMTPS id CF0171862" =>
      "2a01:7c8:aab6:26d:5054:ff:fed1:1da2",
    "from localhost ([127.0.0.1]:49019 helo=hummus.example.uk)\n by hummus.example.uk with esmtp" => "127.0.0.1",
    "from smtp.example.org ([2a02:898:31:0:48:4558:736d:7470]:38689\n helo=mx.example.org)\n by hummus.example.uk" => "2a02:898:31:0:48:4558:736d:7470",
    "from aaa.cn ([1.1.1.1]) by localhost.localdomain (Haraka/2.8.18) with ESMTPA" => "1.1.1.1",
    "from [192.83.172.101] (HELLO 148.251.238.35) (148.251.238.35) by example.com" => "192.83.172.101",
    "from example.com ([]) by example.com with ESMTP id 2019091111" => nil,
    "from 171-29.br (1-1-1-1.z.com.br [1.1.1.1]) by x.com.br (Postfix)" => "1.1.1.1",
    "from [127.0.0.1] ([127.0.0.2]) by smtp.example.com with ESMTPSA" => "127.0.0.2",
    "from 185.118.166.127 (steven2.example.ru [185.118.166.127]) by mail.example.cn" => "185.118.166.127",
    "by mail.example.cn (Postfix) with ESMTPA id AAD722133E34" => nil,
    "(from asterisk@localhost)\n        by pbx.example.com (8.14.7/8.14.7/Submit) id 076Go4wD014562" => nil
  }.freeze

  def test_the_address_each_received_header_came_from
    CASES.each do |value, address|
      assert_equal address.to_s, MailScore::DnsList::Candidates::Received.address(value).to_s, value
    end
  end
end
