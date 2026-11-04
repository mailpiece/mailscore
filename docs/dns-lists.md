# DNS lists

This page describes the `dnsbl` and `uribl` settings: what each list is asked about and how its answers score.
See also [Deploy](deploy.md#dns) for the resolver they go through, and [the example config](mailscore.example.yml).

The code lives in [lib/mailscore/dns_list.rb](../lib/mailscore/dns_list.rb) and [lib/mailscore/dns_list/parser.rb](../lib/mailscore/dns_list/parser.rb), and the recommended lists in [lib/mailscore/dns_list/recommended.yml](../lib/mailscore/dns_list/recommended.yml).

mailscore can ask DNS block lists and allow-lists about the client IP and about the names a message carries: its URLs' domains, its senders, its Message-ID, its DKIM signers and more. It asks none until the config names some, and ships a recommended set, listed under [Recommended lists](#recommended-lists), switched on with one line each:

```yaml
dnsbl: recommended
uribl: recommended
```

Most of these lists are free only for non-commercial, low-volume use, and each has its own terms, such as Spamhaus's [fair use policy](https://www.spamhaus.org/blocklists/dnsbl-fair-use-policy/): check each list's terms before you switch it on.

## Settings

Two settings list zones, or say `recommended`, and take the same keys. `dnsbl` is for lists about the client, and its zones ask about the client IP unless they say otherwise. `uribl` is for lists about domains, and its zones ask about URLs unless they say otherwise. `dnsbl` symbols are in the `rbl` group and `uribl` symbols in `surbl`, which by default weighs at most 12.5 per message; see [Groups](api.md#groups).

```yaml
dnsbl:
  - zone: zen.spamhaus.org          # the zone to ask
    symbol: SPAMHAUS                # fires on an answer no return code or bit names
    weight: 0
    checks: [ from ]                # optional, what to ask about; [ from ] in dnsbl, [ urls ] in uribl
    returncodes:                    # optional, the symbol each answer fires
      SPAMHAUS_SPAM_SOURCE: { weight: 4.0, codes: [ 127.0.0.2 ] }
    returnbits:                     # optional, a symbol for each bit an answer carries
      EXAMPLE_BIT: { weight: 1.0, bit: 2 }
    unknown: true                   # optional, true; fire the zone's symbol for an answer nothing names
    ipv4: true                      # optional, true; ask about IPv4 clients
    ipv6: true                      # optional, true; ask about IPv6 clients
    no_ip: false                    # optional, false; skip URLs to an address
    url_full_hostname: false        # optional, false; ask a URL's whole host, not its registrable domain
    emails_domainonly: false        # optional, false; ask an address's domain, not the address
    dkim_domainonly: true           # optional, true; ask a DKIM signer's registrable domain
    requests_limit: 64              # optional, 64; URLs and addresses from the text asked per message
    prefixes: {}                    # optional, a symbol prefix for each check, see below
    # hash: sha1                    # optional, none; md5, sha1, sha256, sha384, sha512 or blake2
    # hash_format: hex              # optional, hex; base32 or base64 too
    # hash_len: 32                  # optional, the whole digest; how many characters of it to ask
    # emails_delimiter: "."         # optional, between user and domain; "." or "@" with a hash
    is_whitelist: false             # optional, false; an allow-list, asked before the others
    whitelist_exception: []         # optional, the allow-list's symbols that allow nothing
    ignore_whitelist: false         # optional, false; ask even what an allow-list allowed
    exclude_users: true             # optional, true; skip authenticated senders
    exclude_local: true             # optional, true; skip the local networks, and local Received addresses
```

## Checks

| Check | Asks about |
|---|---|
| `from` | the client IP, by its octets for IPv4 (`9.113.0.203.zen.spamhaus.org` for 203.0.113.9) or its nibbles for IPv6, reversed under the zone, if the zone takes that family |
| `received` | each address the top five Received headers say a hop came from, at most `requests_limit`, reversed likewise: not one in the local networks, nor the client IP when the zone also checks `from`. The sender writes every header below those |
| `helo` | the HELO name, as sent |
| `rdns` | the client's host name, from `Hostname` or mailscore's own lookup, unless `unknown` |
| `urls`, `content_urls` | the URLs in the text parts and the Subject: the first of each registrable domain, those of links shown with text first and links without any last, at most `requests_limit`. Each by its registrable domain, or its whole host with `url_full_hostname`, or, for a URL to an address, its octets or nibbles reversed unless `no_ip` |
| `emails` | the addresses in the text and in mailto links, at most `requests_limit` |
| `replyto` | the first Reply-To address |
| `dkim` | the domain of each DKIM signature that verifies, or its registrable domain with `dkim_domainonly` |
| `from_smtp`, `from_mime` | the envelope sender, or the first address in the message's From |
| `mid` | the domain in the Message-ID |

- An address from `emails` or `replyto` loses its `+tag`, and a Gmail address its dots. With `emails_domainonly` it is asked by its domain, and from `emails` by its registrable domain, one per registrable domain, or by its whole domain with `url_full_hostname`. Without it, it is asked as `user.domain`.
- `from_smtp` and `from_mime` ask for the domain with `emails_domainonly`, and for the whole address without it, which only a list with a `hash` is asked.
- A name is asked only as labels of letters, digits, `_` and `-`, at most 253 bytes with the zone, unless the list hashes it.
- A zone with a `hash` is asked the digest of each name that is not an address, in `hash_format` and cut to `hash_len` characters: hex and base32 in lower case, base32 in the z-base-32 alphabet taking each byte's low bits first. Its addresses are asked as `user@domain`.
- With `prefixes`, each check names its symbols, as `prefixes: { from: CLIENT, received: RECEIVED }` turns `SPAMHAUS_SPAM_SOURCE` into `CLIENT_SPAMHAUS_SPAM_SOURCE` for the client IP and `RECEIVED_SPAMHAUS_SPAM_SOURCE` for a Received address. Every check needs a prefix, and `weight` and each return's weight take a number for each prefix. The `_LOOKUP_FAILED` symbol has none.
- Registrable domains come from the public suffix list, so `shop.example.co.uk` is asked as `example.co.uk`. A URL whose host is a public suffix itself is not asked.
- An international domain name is asked in its `xn--` form. A name the DNS cannot carry, with an empty label, a label over 63 characters or one that starts or ends with a dash, is not asked.
- The same name is asked of a zone once, whichever checks found it.
- A zone skips mail from authenticated senders unless `exclude_users` is off, and mail from the local networks unless `exclude_local` is off.

## Answers

- An answer fires every return code or return bit it matches. An answer that matches none fires the zone's own symbol, with the answer in the detail, unless `unknown` is off. A zone with no return codes or bits fires its own symbol for any answer.
- A code with `%` or `[` in it is a pattern, and then all the zone's codes are: `%d` is a digit, `%.` a dot, `[02-9]` a set, `.` any character, and `+`, `*` and `?` repeat what comes before, so `127%.0%.%d+%.1` matches 127.0.15.1. The whole answer must match.
- A symbol fires once however many answers name it, with every name that fired it in the detail.
- A name that is not listed fires nothing. A lookup that times out or fails fires the zone's symbol with `_LOOKUP_FAILED`, such as `SPAMHAUS_LOOKUP_FAILED`, which weighs nothing, with the name and the error in the detail. A lookup the scan budget leaves no time for is not asked and fires nothing.
- Zones with `is_whitelist` are asked first. When one fires a return code or bit not listed in its `whitelist_exception`, the other zones are not asked about that name by the same check, unless they set `ignore_whitelist`: a client IP allowed spares that IP's `from` lookups, and an address allowed by its domain spares the addresses at that domain.
- The lists are asked in parallel, 16 at a time, within the scan budget.
- `/symbols` names each zone, with a label of 20 or more letters and digits, such as a Data Query Service key, shown as `<key>`.

## Recommended lists

`dnsbl: recommended` and `uribl: recommended` ask these lists, with their checks, return codes and weights written as settings in [lib/mailscore/dns_list/recommended.yml](../lib/mailscore/dns_list/recommended.yml).

| Setting | Zone | Symbol | Checks |
|---|---|---|---|
| `dnsbl` | `zen.spamhaus.org` | `SPAMHAUS` | `from`, `received` |
| `dnsbl` | `rep.mailspike.net` | `MAILSPIKE`, an allow-list | `from` |
| `dnsbl` | `list.dnswl.org` | `DNSWL`, an allow-list | `from`, `received` |
| `dnsbl` | `dwl.dnswl.org` | `DNSWL_DOMAIN` | `dkim` |
| `dnsbl` | `bl.spameatingmonkey.net` | `SEM` | `from`, IPv4 |
| `dnsbl` | `bl.ipv6.spameatingmonkey.net` | `SEM_IPV6` | `from`, IPv6 |
| `dnsbl` | `bip.virusfree.cz` | `VIRUSFREE` | `from` |
| `dnsbl` | `bl.blocklist.de` | `BLOCKLIST_DE` | `from`, `received` |
| `uribl` | `ebl.msbl.org` | `MSBL_EMAIL` | `emails`, `replyto`, `from_smtp`, `from_mime`, hashed |
| `uribl` | `email.rspamd.com` | `HASHED_EMAIL` | `emails`, `replyto`, `from_smtp`, `from_mime`, hashed |
| `uribl` | `multi.surbl.org` | `SURBL` | all but `from` and `received` |
| `uribl` | `multi.uribl.com` | `URIBL` | all but `from` and `received` |
| `uribl` | `uribl.rspamd.com` | `HASHED_DOMAIN` | `emails`, `dkim`, `urls`, `content_urls`, hashed |
| `uribl` | `dbl.spamhaus.org` | `SPAMHAUS_DOMAIN` | all but `from` and `received` |
| `uribl` | `uribl.spameatingmonkey.net` | `SEM_DOMAIN` | `emails`, `dkim`, `urls`, `content_urls`, `from_smtp`, `from_mime`, `mid` |
| `uribl` | `fresh15.spameatingmonkey.net` | `SEM_NEW_DOMAIN` | the same |

- A list of your own replaces the recommended set for that setting whole. To keep one of the recommended lists beside your own, copy it from the file.
- `HASHED_DOMAIN` is not asked about the registrable domains of the senders and the Message-ID, which mailscore asks only whole. SURBL's hashbl is left out too, see below.
- Spamhaus refuses queries that reach it through a public resolver, such as 8.8.8.8 or 1.1.1.1, and queries over its free volume, and answers them with `127.255.255.254` and `127.255.255.255`. These fire the `REFUSED` symbols, which weigh nothing, so a refused list scores no mail. Use a resolver of your own, or Spamhaus's Data Query Service with its key in the zone: `<key>.zen.dq.spamhaus.net` and `<key>.dbl.dq.spamhaus.net`. SURBL and URIBL answer a refused query with their `REFUSED` bit, and DNSWL with `DNSWL_REFUSED`, which also weigh nothing. Keep these at 0 in a list of your own.

## What mailscore does not ask

mailscore fetches nothing over HTTP, and asks only what it reads from the message and the envelope:

- It does not ask hash lists that need a map of URL patterns downloaded over HTTP, such as SURBL's hashbl.
- It asks every domain: no list of popular domains is kept out of the URL lists.
- It does not follow redirectors or read URLs from PDFs and other attachments. `content_urls` and `urls` read the text parts and the Subject only.
- When a message has more than 64 domains, it asks the first 64 it finds.
- It asks every zone, with no background check of whether a zone still answers, and leaves a refusal to the `REFUSED` codes.
- It reads the address in a Received header's first comment, or after `from`, which covers the common Received formats.
