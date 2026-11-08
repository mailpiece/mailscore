# HTTP API

This page describes the HTTP API: its tokens, its endpoints, and what a caller does with each verdict.
See also [Deploy](deploy.md) and [DNS lists](dns-lists.md).

The code lives in [lib/mailscore/app.rb](../lib/mailscore/app.rb) and [lib/mailscore/scanner.rb](../lib/mailscore/scanner.rb).

Paths are unversioned. A breaking change to one endpoint gets a new name beside the old one, such as `/check2`.

The caller is any receiving mail server. It collects the envelope during the SMTP session, sends the whole message once after DATA, and acts on the one verdict it gets back. mailscore never talks SMTP, never stores mail and never delivers it.

## Transport

- JSON responses, except `GET /ping`. A request body is a raw message (`Content-Type: message/rfc822`).
- Plain HTTP on a private network only, such as the container network. Never published on a host port: the tokens and the mail cross it in the clear.
- A body larger than the message size cap gets `413`. The cap is a setting, 50 MB by default. A body more than 64 KB past it is refused unread, with a plain-text `413`.

## Tokens

Two tokens, both from ENV, sent as `Authorization: Bearer <token>`:

- The read token scans, and reads stats, symbols and health detail.
- The write token learns, adds and deletes fuzzy hashes, and does anything else that changes state. It also does everything the read token does.

Each token should be at least 32 characters, or mailscore logs a warning at boot; `openssl rand -hex 32` makes one. If only one token is configured, it serves both. A missing or wrong token gets `401`, with no log line. `/stats` counts them as `unauthorized`, each worker's own count written with its next request that has a token.

The read token is not harmless to leak. Whoever holds it can submit any mail for scoring, and each scan records greylisting and reputation, and with `autolearn` or traps on, learns from the mail, so it can shape later verdicts. It also reads stats and symbols, which name every DNS list zone. Keep it as secret as the write token.

`GET /ping` needs no token.

## `POST /check`

One scan per message, after DATA. The body is the raw message. Read token.

Request headers, all optional:

| Header | Value |
|---|---|
| `IP` | client IP |
| `Helo` | HELO or EHLO argument |
| `Hostname` | the client's verified reverse DNS name, or, when it has none, `unknown` or its address in brackets, such as `[203.0.113.9]` |
| `Reverse-DNS-Status` | how the caller's reverse DNS lookup went: `confirmed`, `unconfirmed`, `none` or `temporary_failure` |
| `Unconfirmed-Hostname` | the name the client's PTR record gave when it did not resolve back to the client IP |
| `From` | envelope sender, `<>` for a null sender |
| `Rcpt` | one envelope recipient, repeated for each |
| `Deliver-To` | the final delivery address, when the caller knows it |
| `User` | the authenticated user, for an authenticated session |
| `TLS-Version` | protocol version |
| `TLS-Cipher` | cipher name |
| `Queue-Id` | the caller's id for the message, for logs |

- `Rcpt` may be repeated or carry a comma-separated list.
- Without `From` or `Rcpt`, mailscore reads the message's own `From` and `To`, which the sender writes as it likes. Traps, greylisting and the bounce checks then go by them, so a caller should always send the envelope it saw.
- Without `IP`, checks that need the client IP do not fire.
- Without `Hostname`, or with only the address in brackets, mailscore looks up the client IP's PTR record itself, within the scan budget, and takes the first name as the client's host name without checking it resolves back. No PTR record fires `REVERSE_DNS_NONE` and `HOSTNAME_UNKNOWN`. A lookup that timed out or got a server failure says nothing either way and fires only `REVERSE_DNS_LOOKUP_FAILED`. `unknown` fires `HOSTNAME_UNKNOWN` with no lookup. All three weigh 0 by default, so reverse DNS shows in the verdict but adds nothing to the score unless `scores` gives it a weight. Local networks and authenticated senders are not looked up.
- `Reverse-DNS-Status: temporary_failure` says the caller's own lookup timed out or got a server failure. mailscore does not look up again and fires only `REVERSE_DNS_LOOKUP_FAILED`, whatever `Hostname` says. A caller that skipped its lookup leaves the header out, so mailscore looks up itself. With `confirmed`, `unconfirmed` or `none`, `Hostname` alone says whether the client has a name; any value not listed is ignored.
- `Unconfirmed-Hostname` is anyone's to claim, since whoever controls the client IP's reverse zone writes it. mailscore never takes it as the client's host name, so it never stands in for `Hostname`, never lowers a score and never passes a check. A value that is not a full host name, with at least one dot, only letters, digits and hyphens in its labels and at most 253 characters, is ignored.
- mailscore runs SPF, DKIM, DMARC and ARC itself.

Response, one verdict for the message:

```json
{
  "action": "add header",
  "score": 7.1,
  "complete": true,
  "symbols": [ { "name": "HELO_IP_ADDRESS", "weight": 3.0, "detail": "[203.0.113.9]", "description": "Server greeted with an IP address" } ]
}
```

- `score` is the sum of the fired symbols' weights, each within its group's cap; see [Groups](#groups).
- Every score, weight and threshold is a float, such as `0.0` or `12.0`, here and in `/symbols`, however the config writes it.
- `scores` sets a symbol's weight, or switches it off so it never fires. A symbol that fires at part of its weight, such as Bayes by its confidence, fires at the same part of the new one. The score, the action, reputation and autolearn all count the weight in use. A symbol switched off is gone entirely, so `off` on `DKIM_PASS` or `SPF_PASS` also stops DKIM or SPF reputation and `off` on `BAYES_SPAM` or `BAYES_HAM` stops autolearn seeing Bayes's call; to drop only the weight, set it to 0. `GREYLISTED` has no score: switch greylisting off with `actions`.
- `symbols` lists every symbol that fired. `name` is a symbol from `/symbols`, `weight` what it added to the score, `detail`, when present, what it fired on, and `description` the one `/symbols` gives it.
- `complete` is false when the scan ran past its budget. See [Timeout](#timeout).
- `smtp_reply` (`code`, `enhanced`, `text`) is present with `soft reject` and `reject`, and mailscore always sends one that is well formed: `code` is a 4xx with `soft reject` and a 5xx with `reject`, `enhanced` is `class.subject.detail` with the same class digit, and `text` is printable ASCII with no CR or LF, at most 200 characters. The caller uses its own reply for one that is not.
- Greylisting and `soft reject` send `451`, `4.7.1` and "Try again later". `reject` sends `554`, `5.7.1` and "Spam message rejected".
- `subject` is present with `rewrite subject`: the new Subject, the template around the message' Subject with its MIME encoded words decoded. When it is not all printable ASCII, it is sent as UTF-8 encoded words, so it never carries a CR, an LF or raw 8-bit text.

`/check` has this one shape. Other response shapes, or a milter front for MTAs that speak milter, can be added later under new names, without changing `/check`.

## Actions

The action is the highest one whose threshold the score reaches. `greylist` is internal: it never reaches the caller as a final answer.

With greylisting on, any score at or above the greylist threshold and below reject, including `add header` and `rewrite subject`, gets `soft reject` the first time it is seen. The caller sees that action only on a retry that passes the greylist. See [Greylisting](#greylisting).

| Action | Caller does |
|---|---|
| `no action` | accept |
| `add header` | accept, marked as spam, such as with `X-Spam: Yes` |
| `rewrite subject` | accept, with its Subject set to `subject` |
| `soft reject` | reply with `smtp_reply`, a 4xx |
| `reject` | reply with `smtp_reply`, a 5xx |

Each threshold is a setting, by default greylist 4, add header 6 and reject 15, with rewrite subject and soft reject off. An action can be switched off, and a config that sets some thresholds keeps the defaults for the rest.

One verdict covers every recipient. The caller applies it as its reply to DATA.

## Greylisting

Greylisting runs after DATA, when the score reaches the greylist threshold and the action is anything but `reject`. Switching the greylist threshold off switches greylisting off.

- Entries are keyed on sender, recipients and client network (IPv4 masked to /19, IPv6 to /64), and on a hash of the first 10 KB of the body with the Subject, the recipients and the message's own From.
- A new message, or one retried before the timeout, gets `soft reject` with the symbol `GREYLISTED` (option `greylisted`) and the reply "Try again later".
- A retry after the timeout that matches either key passes. It gets the action its score gives, `no action` when that is only `greylist`, and the symbol `GREYLISTED` (option `pass`, weight 0).
- A score at or above reject is rejected at once, never greylisted.
- Entries expire after the expiry, counted from first sight. A retry before the timeout does not extend it; a retry that passes pushes it back by the expiry.
- Mail from local networks and authenticated senders passes the same way.

The timeout and the expiry are settings, 5 minutes and 1 day by default.

## Reputation

mailscore remembers how mail from these selectors has scored:

- the client IP, an IPv6 one as its /64,
- the organizational domain of each DKIM signer that passed, aligned with the `From` header or not, so `mail.example.co.uk` counts as `example.co.uk`; a `d=` that is not a host name, such as one holding a comma, never passes (`DKIM_INVALID`) and is left out of the DKIM symbols' detail, and
- the SPF record that passed, the one the `From` request header's domain publishes, or the `Helo`'s for a bounce, keyed by the first 32 hex digits of its SHA-256, so domains publishing the same record share one reputation. A pass by `+all` is `SPF_ALLOWS_ANYONE` and counts for nothing, and a pass without a record of the domain's own, such as when it published two, counts for nothing too.

A domain nothing authenticates has no reputation, so a forged one is neither poisoned nor borrowed.

A record shared by a large provider's customers, such as `v=spf1 include:_spf.google.com ~all`, pools them all. `spf_reputation_exclusions` lists keys whose reputation is not kept, as `SPF_REPUTATION_SPAM` and `SPF_REPUTATION_HAM` show them; that record's is `cba2374ed98ba8a6a44b27e7b9239984`. It is empty by default.

With the optional `asn_database` and `country_database` settings, two more selectors count for the client IP: its autonomous system and the country its network is registered in, read from local MaxMind-format files such as GeoLite2-ASN and GeoLite2-Country. mailscore ships neither file and looks nothing up over the network. Without them, the IP scores alone.

After each complete scan, each selector keeps a count of messages and a moving average of their scores. A selector records the scan's score less its own symbol, so a sender pushed to reject by its IP reputation is recorded by what the rest of the message scored. The average moves toward each new score by `1 - e^(-t / window)`, where `t` is the time since the selector was last recorded, and the first score sets it. A scan reads reputation before its own message is recorded, so a message never scores itself. A greylisted first attempt is not recorded; its retry records the real outcome. Incomplete scans, and mail from local networks and authenticated senders, are neither recorded nor scored.

Once a selector has recorded the minimum count of messages, it scores `tanh(average / reject × 1.83178 − 0.5493)`, where `reject` is the reject threshold, or 10 with reject off. An average of 0 scores -0.5, one at the threshold 0.86, and the score never passes -1 or 1. A symbol fires with its weight in the table times the total of its selectors' scores:

- `IP_REPUTATION_*` is the IP's score, plus the ASN's times 0.4 and the country's times 0.01, so up to 1.41.
- `DKIM_REPUTATION_*` is the sum of the signers' scores, held between -1 and 1.
- The others take their one selector's score.

The detail lists each selector that scored, its own score and its count, such as `203.0.113.9 score=0.82 count=34, AS64500 score=0.4 count=310`. A symbol whose total is within 0.001 of zero does not fire.

| Symbol | Selectors | Weight at a total of 1 |
|---|---|---|
| `IP_REPUTATION_SPAM` | client IP, ASN, country | 3.0 |
| `IP_REPUTATION_HAM` | client IP, ASN, country | -1.0 |
| `DKIM_REPUTATION_SPAM` | DKIM signers | 3.0 |
| `DKIM_REPUTATION_HAM` | DKIM signers | -1.0 |
| `SPF_REPUTATION_SPAM` | SPF record | 3.0 |
| `SPF_REPUTATION_HAM` | SPF record | -1.0 |

The window (30 days), the minimum count (10) and the expiry of a selector unseen (10 days) are optional settings. Upgrading from the earlier counts drops the reputation table and starts it afresh. Learning does not feed reputation.

## Timeout

The scan budget is a setting, 8 seconds by default.

- Past the budget, mailscore answers with what it has, `complete` is false, and `SCAN_TIMED_OUT` fires, its detail the first rule skipped.
- The budget is checked between rules: a rule that has started runs to its end, and DNS lookups are cut to the time left.
- An option turns a timeout into `soft reject`, unless what the scan has so far already reaches `reject`, which stands. It is off by default.

`SCAN_TIMED_OUT` weighs 3.0, about what one of the last rules to run, a DNS list, Bayes or fastText, adds for spam, so a message cannot score low by being slow to scan. Alone it stays short of the greylist threshold, so a slow nameserver costs good mail nothing; with a little else against the message, it greylists it, and the retry is scanned afresh.

The caller's SMTP session waits on `/check` up to the budget, while mailscore may do DNS.

## Limits

mailscore reads a message only so far. Past a cap the rest is skipped, and the cap fires its symbol:

| Symbol | Weight | Cap |
|---|---|---|
| `TOO_MANY_HEADERS` | 1.0 | 1,000 header fields, or 1 MB of them, in the message or any part. The rest are not read, by authentication either |
| `TOO_MANY_PARTS` | 1.0 | 1,000 MIME parts, nested ones counted, depth first, or 64 MB of their bodies, a nested part counted again at each level |
| `TOO_MANY_ZIP_ENTRIES` | 0.0 | 1,000 entry names in a zip, or 64 KB of them, and 5,000 in a message. A name keeps its last 255 bytes, where its file name and extension are |
| `TOO_MANY_LINKS` | 0.0 | 1,000 distinct URLs, those of links shown with text first, then the text's, then links without text, each domain's first before any second; or more URL domains than a DNS list's `requests_limit` |

A cap no ordinary mail reaches weighs a little; one a long newsletter may reach weighs nothing.

## Groups

Every symbol belongs to one group, such as `headers`, `hostname`, `policies`, `dnsbl` for `dnsbl` lists and `uribl` for `uribl` lists. `/symbols` gives each symbol's group. The `groups` setting caps what a group adds with `max_score` and `min_score`:

```yaml
groups:
  headers: { max_score: 0 }    # no cap
  hostname: { max_score: 6 }
```

Symbols count in the order they fire. One that takes its group's total past `max_score` adds only what is left, and every later one of the same sign adds 0; a negative total stops at `min_score` the same way. A capped symbol still fires, with the weight it added, and the score, the action, reputation and autolearn all read that weight. `max_score` is 0 or more and `min_score` 0 or less; 0 is no cap. By default these groups are capped, and any other is uncapped:

| Group | `max_score` |
|---|---|
| `headers` | 8 |
| `subject` | 6 |
| `phishing` | 10 |
| `mime_types` | 10 |
| `url` | 9 |
| `uribl` | 12.5 |

## Rules

Some symbols the caller relies on:

| Symbol | Weight | Fires when |
|---|---|---|
| `BOUNCE` | -0.1 | a null `From` request header with a top-level `multipart/report` of `delivery-status` or `disposition-notification`. Short of a report, it weighs -0.05 for a `postmaster` or `mailer-daemon` message From with bounce words in the Subject or a returned message in its first parts, and -0.02 for bounce words with a returned message |
| `BOUNCE_MANY_RECIPIENTS` | 1.5 | a null or `postmaster@` `From` request header to more than one recipient |
| `DMARC_FAIL_REJECT_POLICY` | 5.5 | DMARC fails and the policy is `p=reject` |
| `DMARC_FAIL_QUARANTINE_POLICY` | 4.0 | DMARC fails and the policy is `p=quarantine`, or `p=reject` outside the `pct` sample |

- When SPF, DKIM, DMARC and ARC fail to run, `AUTHENTICATION_ERROR` (2.0) fires in place of all their symbols, so a message cannot shed an authentication failure by making the checks raise.
- A DKIM signature whose `l=` leaves part of the body unsigned earns nothing: no `DKIM_PASS`, no DMARC alignment, no signer reputation and no DNS allow-list. Alone it fires `DKIM_PARTIAL_BODY` (0.5).
- Bounces and mail from `<>` are scored like any other mail.
- An attachment whose first bytes show a program, under a name with an extension not on the `risky_extensions` list, fires `ATTACHMENT_DISGUISED_PROGRAM` (12.0), such as a Windows executable named `invoice.pdf`. A program is a Windows executable (`MZ` and the `PE` signature its header points at), an ELF or Mach-O binary, a Java class, a Windows shortcut, a virtual hard disk, a script starting `#!`, or a zip holding an Android app or a Java program. It is alone in the `programs` group, uncapped by default, so it adds its full weight whatever else `mime_types` fired.
- The standard anti-spam test string, anywhere in the subject, the headers or a text or HTML part, fires `SPAM_TEST_STRING` (0.0) and forces `reject` whatever the score, for checking a filter end to end. `scores` switching the symbol off stops it, and with `reject` switched off in `actions` the score decides.
- A DMARC `p=reject` failure only adds weight. It never forces a reject, but a spoof still reaches `greylist` past every credit a sender can earn for itself: SPF and DKIM passes for its own domain, its own ARC seal and a bounce.
- When `pct` leaves a failure out of the sample, `p=reject` counts as `p=quarantine`.
- A single From field that names no single domain DMARC can check, such as an address only in a quoted name, fires `FROM_UNREADABLE` (7.5) in DMARC's place. Honest mail does not send one, and it shows a reader a sender no check can hold to account, so it weighs just under `FROM_MULTIPLE_ADDRESSES` (8.0), which shows several. Several addresses fire `FROM_MULTIPLE_ADDRESSES`, and none `FROM_MISSING`.
- SPF checks the `From` request header, never the message's own From, and `postmaster@` the HELO for `<>`. Without `IP` or `From`, SPF and DMARC are skipped; DKIM and ARC still run.
- An SPF symbol's detail is the domain checked, then the record it publishes when it has one of its own, such as `example.com v=spf1 ip4:192.0.2.1 -all`.
- An SPF pass from a record that lets any client send, with `+all` or a bare `all` in it or in an `include` or `redirect` it read, fires `SPF_ALLOWS_ANYONE` at 4.0 instead of `SPF_PASS`. DMARC still counts it as a pass, but it gives the sender no SPF reputation.
- Mail from local networks and authenticated senders skips SPF, DKIM, DMARC, the HELO and PTR checks, the DNS lists that say so and `BOUNCE_MANY_RECIPIENTS`; ARC, header and content rules still run.
- DNS lists for the client IP and for the domains a message carries are off by default. Each one the config names fires its own symbols; see [DNS lists](dns-lists.md).

## `POST /learn/spam`, `POST /learn/ham`

Teach the Bayes classifier. There is one, for all mail. The body is the raw message, sent again each time. Write token.

- `200` and `{"learned": true}` when learned.
- The same message learned again as the same class: `208` and `{"error": "already_learned"}`.
- A message with fewer than `bayes_min_tokens` tokens, 11 by default, is too short to learn: `204` with no body, and nothing is learned.
- The same message learned as the other class is relearned: its counts move to the new class.
- A message is known by a digest of its Bayes tokens, so headers the caller added since the scan, and changes the tokens do not see, such as case and punctuation, do not matter.
- The read token gets `401`.
- There is no unlearn endpoint.
- A learn is always heard, however sure the classifier already is: a person correcting the filter is never turned away.

In `/check`, once each class has the minimum learns (200), the classifier fires `BAYES_SPAM`, up to 5.1, or `BAYES_HAM`, down to -3.0. The weight is the full weight times the eighth power of the confidence, `(p - 0.5) * 2` for the class named, so only a near-certain call weighs much, and nothing fires within 0.05 of even, or for a message with fewer than `bayes_min_tokens` tokens, 11 by default. A token counts only once it has appeared in at least 2 learned messages, of either class, so with few learns a message whose tokens are still new leaves Bayes silent, even past `bayes_min_learns`. The detail is the confidence, such as `90.00%`. The classifier reads orthogonal sparse bigrams of the Subject and of each text part on its own, with Robinson's token probabilities and Fisher's method to combine them. With `language_model` set to a fastText language identification model you supply, such as `lid.176.ftz` (CC BY-SA 3.0, not shipped), each part's words are stemmed with Snowball for the language it detects, and the Subject's for the first part's, and a stop word of any language Snowball lists is dropped; without it, every part is taken as English.

With `fasttext` on, every learn, by hand, by autolearn or by a trap, also keeps the words of the message, its Subject then its text up to 1,000, to train the fastText model on. A scan alone keeps nothing.

The fastText model is one supervised classifier for all mail, over the same words. Once each class has 200 samples, a setting, it is trained daily on four fifths of them, and a new model replaces the one in place only when it does at least as well on the fifth both were held from. 200 is a low bar for a confident model; raise it once there is mail to learn from. In `/check` it fires `FASTTEXT_SPAM`, up to 3.0, or `FASTTEXT_HAM`, down to -2.0: the full weight times the confidence, with nothing within 0.05 of even, the detail the confidence as with Bayes. The weights sit below Bayes' because the model learns from the same mail, so the two mostly agree, and fastText is sure of itself even on little data. With `fasttext` off, or before the first model, it is skipped.

Autolearn exists and is off by default. When on, it learns spam above the reject threshold, or above 15 with reject off, and ham below 0. Setting `autolearn_spam_score` or `autolearn_ham_score` learns at or past that score instead. It skips mail from local networks and authenticated senders, mail `BAYES_SPAM` or `BAYES_HAM` already calls the class it would learn, at any weight, and a greylisted first attempt, whose retry is learned instead.

## Traps

Trap addresses are a setting, off by default. When on, mail to a trap can:

- add its fuzzy hashes, as `trap_fuzzy_weight` reports in one, 10 by default, and
- be learned as spam.

Each is a separate switch, off by default. Both skip mail from local networks and authenticated senders.

- A trap acts only when it is the message's sole recipient. Mail to a trap and other recipients is left alone: no `SENT_TO_TRAP`, no `trap_hits`, no hashes and no learning. A switch, off by default, lets a trap act beside other recipients too.
- A recipient matches a trap address in any case. Both run after the verdict, so the message never scores itself; a message already learned as spam is fine.
- Mail to a trap fires `SENT_TO_TRAP`, weight 10.0, in `/check`, without naming the address. Only spammers write to traps, but an old address turned trap still gets the odd stray, and with the switch on a trap can share a message with real recipients, so it stays below the suggested reject threshold of 15.
- `/stats` counts `trap_hits`.

## `POST /fuzzy/add`, `POST /fuzzy/delete`, `POST /fuzzy/check`

Fuzzy hashes, one store for all mail. The body is the raw message. mailscore computes the hashes:

- a text part of at least 64 words, as 32 shingles and an exact hash of its words,
- a shorter text part, as an exact hash of its words and the Subject, once their bytes times four reach 1024,
- an attachment of an `application/*` type, from 1024 bytes, as an exact hash, and
- an image at least 500 pixels wide and high, PNG, GIF or JPEG, from 1024 bytes, as an exact hash. Smaller images, such as logos, are not hashed.

A message gives at most 100 distinct hashes, its first; past that the log notes how many it had.

- `add` and `delete` take the write token and a `Flag` header, such as `spam`. An unknown flag gets `422`. Response: `{"hashes": 3}`, the message's hash count, for `delete` too, whether or not they were stored.
- `add` takes an optional `Weight` header, a positive whole number, 1 by default, which it adds to each hash's count. Any other value is ignored and counts as 1.
- `check` takes the read token. Response: `{"matches": [ { "flag": "spam", "count": 41, "similarity": 0.92 } ]}`.

A match also fires its flag's symbol in `/check`, and `/symbols` lists the configured flags' symbols and weights.

- A near match shares more than 16 of a text's 32 shingles. An exact match has similarity 1.0.
- The symbol's weight is the flag's weight × tanh(e × count / hits limit) × (similarity − 0.5) / 0.5. It nears the flag's weight once the count reaches the hits limit, and falls to nothing as the similarity falls to a half.

| Flag | Symbol | Weight | Hits limit |
|---|---|---|---|
| `spam` | `FUZZY_SPAM` | 12.0 | 20 |
| `prob` | `FUZZY_PROBABLE_SPAM` | 5.0 | 10 |
| `ham` | `FUZZY_HAM` | -2.1 | 2 |

The flags are a setting, and these three are the default.

## `GET /ping`, `/health`, `/stats`, `/symbols`

- `ping`: no token. `200` and `pong` as plain text, for container health checks.
- `health`: read token. `200` and `{"status": "ok", "version": "0.3.0"}` when the database opens. `503` otherwise.
- `stats`: read token. Counters since start, such as scans per action, budget overruns, rule errors, scan errors, learns, autolearns and fuzzy matches. Never message content or addresses. Under `fasttext`, the model in place: its accuracy on held-out samples and the spam and ham samples it learned from, and the time of the last training, swapped in or not, as `{"trained_at": "2026-11-03T03:00:00Z", "accuracy": 0.97, "spam_samples": 4000, "ham_samples": 4000}`, with nulls before any.
- `symbols`: read token. The rule catalogue, `[ { "name": "HELO_IP_ADDRESS", "weight": 3.0, "description": "Server greeted with an IP address", "group": "hostname" } ]`, each at the weight in use. A symbol `scores` switches off keeps its default weight and adds `"disabled": true`. A description is a short label, such as "No reverse DNS for the sending server".

## Errors

| Status | Meaning |
|---|---|
| `400` | malformed request |
| `401` | wrong or missing token |
| `413` | body over the cap |
| `422` | refused, such as an unknown fuzzy flag |
| `503` | overloaded or database down |

Error bodies are `{"error": "<code>"}`. Whether to accept unscored mail on an error is the caller's choice.

A scan that fails on the message itself still answers `200`, with `complete` false and `SCAN_ERROR` (3.0) as its only symbol, so a message cannot score low by making the scan fail. The log names the error's class alone, and `/stats` counts `scan_errors`.
