# Deploy

This page describes how to build, configure, run and check the container image.
See also [HTTP API](api.md), [DNS lists](dns-lists.md) and [the example config](mailscore.example.yml).

The code lives in [lib/mailscore/server.rb](../lib/mailscore/server.rb), [lib/mailscore/config.rb](../lib/mailscore/config.rb) and the [Dockerfile](../Dockerfile).

mailscore ships as a container image. It listens on 8080 inside a private network, keeps its state in one SQLite database on a volume, and runs as a non-root user (UID and GID 1000) on a read-only filesystem.

## Image

Each release publishes the image to `ghcr.io/mailpiece/mailscore`, for linux/amd64 and linux/arm64, tagged with its version:

```sh
docker pull ghcr.io/mailpiece/mailscore:0.1.1
```

Pin the exact version, as the examples below do, and never `latest`, so a deploy runs the release you chose. A release is published only from a commit CI has passed, and CI checks the image built from it: it boots read-only and answers `/ping`, carries no setuid or setgid binaries, and has no fixable High or Critical vulnerability. Every CI run builds the image and keeps a CycloneDX SBOM of it as a workflow artifact.

To build it yourself, from a checkout:

```sh
docker build --build-arg RUBY_VERSION=$(cat .ruby-version) -t registry.example.com/mailscore:<commit> .
```

The build needs network: it installs the gems from the committed lockfile, for x86_64 and aarch64 Linux, and runs `bundle-audit` against a fresh advisory database, so a known vulnerability fails the build.

The image runs `mailscore`, which reads `/etc/mailscore.yml` when one is mounted and runs on the defaults otherwise. Pass a path as the command to read another file instead.

### Verify the image

The release signs the image with cosign, keyless, and attests its build provenance on GitHub, both for the multi-arch manifest. Check both before you deploy a version:

```sh
cosign verify ghcr.io/mailpiece/mailscore:0.1.1 \
  --certificate-identity-regexp 'github.com/mailpiece/mailscore/' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
gh attestation verify oci://ghcr.io/mailpiece/mailscore:0.1.1 --owner mailpiece
```

## Configuration

Every setting has a default, so a config file is optional. To change one, mount a file at `/etc/mailscore.yml` holding only what differs; [mailscore.example.yml](mailscore.example.yml) lists every setting with its default. The database defaults to `/data/mailscore.sqlite3`, on the volume; keep it under `/data` if you move it.

The tokens come from ENV: `MAILSCORE_READ_TOKEN` and `MAILSCORE_WRITE_TOKEN`. Each should be at least 32 characters; keep both secret: the read token submits mail that greylisting, reputation and autolearn record. See [Tokens](api.md#tokens).

The API is plain HTTP, with no TLS: the tokens and the mail cross the network in the clear. Run it on a private network only, such as the container network, and never publish its port on a host.

Leave `PUMA_DEBUG` unset in production. With it set, Puma writes the headers, the token among them, and the body of a request that errors to the log.

For ASN and country reputation, mount GeoLite2-ASN.mmdb and GeoLite2-Country.mmdb read-only, such as `-v /var/lib/GeoIP:/geoip:ro`, and set `asn_database` and `country_database` to them; downloading them, with `geoipupdate` or by hand, takes a free MaxMind account and its licence key, which stays on the host. Restart mailscore after an update: each worker keeps the files it opened.

The `shorteners`, `trusted_redirectors`, `risky_extensions` and `archive_extensions` files can be replaced without a restart: each worker checks every 30 seconds whether a file changed and reads it again once it has, keeping the last list, with a warning, while the file is missing or can't be read. Mount the directory that holds them, such as `-v /etc/mailscore/lists:/lists:ro`, rather than each file, and write a new file beside the old one and rename it over, so a worker never reads half a file.

## Logs

mailscore logs to stdout, so the container's logs hold them. Each `/check` writes one line at `info`, such as:

```
I, [2026-11-03T14:19:45.405128 #7]  INFO -- mailscore: scan queue_id=4Xk2Lq0Rz9 action=add_header score=6.0 complete=true ms=12 ip=203.0.113.9
```

- `queue_id` is the caller's `Queue-Id` and `ip` its `IP` header, `-` when absent, so a scan can be matched to the mail server's log. Each keeps only printable ASCII without spaces, up to 64 characters, so a caller can't forge a line or a field.
- `action` is the verdict's, `score` its score, `complete` false past the budget, and `ms` how long the scan took.
- Learns and fuzzy changes write a line each: `learn` with the class and `learned`, `already_learned` or `too_short`, and `fuzzy_add` or `fuzzy_delete` with the flag and the number of hashes.
- A rule that raises logs its name and error class at `error`, as do failed trap, reputation, autolearn, expiry and training writes.
- A lookup of the `nameservers` host names that fails after boot logs at `warn`, and the last addresses stay in use.
- A line never holds message content, a Subject or an address.

Set `log_level` to `warn` or `error` to leave out the lines per request.

## Kamal

Run mailscore as an accessory of the app that calls it. Kamal is the main example, with Docker Compose after it. Any orchestrator that can set the same `docker run` flags works.

```yaml
# config/deploy.yml
accessories:
  mailscore:
    image: ghcr.io/mailpiece/mailscore:0.1.1
    host: mail.example.com
    files:
      - config/mailscore.yml:/etc/mailscore.yml # optional, the settings that differ
    volumes:
      - mailscore:/data                     # the database and its WAL
    env:
      secret:
        - MAILSCORE_READ_TOKEN
        - MAILSCORE_WRITE_TOKEN
    options:
      # Performance. Docker applies no limit if unspecified. Examples, not recommendations.
      cpus: 2
      memory: 1g
      memory-swap: 1g                       # equal to memory, or swap defeats the limit

      # Security. Be cautious changing these, as that may impact security posture.
      read-only: true
      cap-drop: ALL
      security-opt: no-new-privileges:true
      user: 1000:1000
      pids-limit: 256

      # Both: size=256m is performance, the three flags before it are security.
      tmpfs: /tmp:rw,nosuid,nodev,noexec,size=256m

  # A recursive resolver of your own, needed only for DNS lists queried
  # without a key. See DNS below.
  unbound:
    image: klutchell/unbound:1.26.2
    host: mail.example.com
```

No `port:`, so mailscore stays on the Docker network Kamal creates, and nothing is published on the host. The app reaches it at `http://<service>-mailscore:8080`, where `<service>` is the `service:` in `deploy.yml`. A new named volume takes the image's ownership; a host directory must be owned by UID 1000.

With the resolver, set `nameservers: [ <service>-unbound ]` in `config/mailscore.yml`.

## Docker Compose

The same setup in Compose, also in [compose.example.yaml](compose.example.yaml). With the resolver, set `nameservers: [ unbound ]` in `mailscore.yml`. `app` stands for whatever calls mailscore, at `http://mailscore:8080`.

```yaml
services:
  mailscore:
    image: ghcr.io/mailpiece/mailscore:0.1.1
    depends_on:
      - unbound
    environment:
      - MAILSCORE_READ_TOKEN
      - MAILSCORE_WRITE_TOKEN
    volumes:
      - mailscore:/data                    # the database and its WAL
      - ./mailscore.yml:/etc/mailscore.yml:ro # optional, the settings that differ
    networks:
      - mail
    # For local testing only:
    # ports:
    #   - "127.0.0.1:8080:8080"

    # Performance. Docker applies no limit if unspecified. Examples, not
    # recommendations; see the performance flags in deploy.md to size them.
    cpus: 2
    mem_limit: 1g
    memswap_limit: 1g                      # equal to mem_limit, or swap defeats the limit

    # Security. Be cautious changing these, as that may impact security posture.
    read_only: true
    tmpfs:
      - /tmp:rw,nosuid,nodev,noexec,size=256m # size is performance, the rest security
    cap_drop:
      - ALL
    security_opt:
      - no-new-privileges:true
    user: "1000:1000"
    pids_limit: 256
    restart: unless-stopped

  # A recursive resolver of your own, needed only for DNS lists queried
  # without a key. mailscore asks it with nameservers: [ unbound ].
  unbound:
    image: klutchell/unbound:1.26.2
    networks:
      - mail
    restart: unless-stopped

  # Whatever calls mailscore.
  app:
    image: registry.example.com/app:<commit>
    environment:
      - MAILSCORE_URL=http://mailscore:8080
      - MAILSCORE_READ_TOKEN
      - MAILSCORE_WRITE_TOKEN
    networks:
      - mail

networks:
  mail:

volumes:
  mailscore:
```

## Container flags

These are `docker run` flags. Under Kamal, they go in an accessory's `options:`; Compose has a service key for each, such as `cap_drop` and `mem_limit`.

mailscore keeps its network, unlike a sandbox: it answers callers over HTTP, and it looks up SPF, DKIM, DMARC, ARC, PTR records and DNS lists for every message.

### Performance flags

These flags have no defaults: Docker applies no limit for a flag that you omit. Size each one from your workload and your hardware. The examples are from the accessory above, and they aren't recommendations.

Measured on synthetic mail, each Puma process takes about 45 to 70 MB. The look-alike tables are loaded before the workers fork and shared with them. With `fasttext` on, a training runs in a child process and peaked near 215 MB at 5,000 samples a class. With `language_model` set, the model adds 1 MB for `lid.176.ftz` or 126 MB for `lid.176.bin`, shared by the workers.

| Flag | Example | Description |
| --- | --- | --- |
| `cpus` | `2` | The share of the host that mailscore can use. Scans run in parallel only across processes, so set `workers` to this number, not to the host's CPUs. |
| `memory` | `1g` | The cgroup limit, which counts every process and the tmpfs. Size it from `workers` plus one, for the master, times the per-process RSS, plus the messages being scanned, held whole with their decoded parts, the training child's peak with `fasttext` on, the language model, and the tmpfs. |
| `memory-swap` | `1g` | Set it equal to `memory`. If you omit it, Docker allows twice `memory` in swap, and the memory limit no longer holds. |
| `tmpfs` size | `size=256m` | Puma buffers request bodies over 112 KB to `/tmp`, up to `message_size_cap` each, for every request in flight, and SQLite puts its temporary files there. With `fasttext` on, a training also writes its input there, about the size of the samples. |

### Security flags

Use these values. If you omit one, the protection is gone, and mailscore still answers exactly as before.

| Flag | Recommended | Description |
| --- | --- | --- |
| `read-only` | `true` | Makes the root filesystem read-only. mailscore writes only to `/data` and `/tmp`. |
| `tmpfs` flags | `rw,nosuid,nodev,noexec` | `noexec` stops a dropped binary from running from `/tmp`. Nothing mailscore runs needs it: request bodies, SQLite's temporary files and the training input are only read and written there. |
| `cap-drop` | `ALL` | Removes every Linux capability. mailscore listens on 8080 and needs none. |
| `security-opt` | `no-new-privileges:true` | Prevents a setuid binary from regaining what `cap-drop` removed. |
| `user` | `1000:1000` | The image's own user, which owns `/data`. |
| `pids-limit` | `256` | Bounds processes and threads together. Each worker runs up to 5 request threads, each starting up to 16 threads for DNS lists, plus Puma's own and two background threads: about 100 a worker. Add a few for the master and the training child, and check it when you raise `workers`. |

## DNS

mailscore's only outbound traffic is DNS, through the resolver in the container's `/etc/resolv.conf`, or the `nameservers` setting: SPF, DKIM, DMARC and ARC for every message, and the client's PTR record when the caller sends no `Hostname`. With no `dnsbl` or `uribl` set, it needs nothing beyond that.

Each DNS list you set adds queries to that list's servers through the same resolver, one per message for the client IP and one per domain for URLs. A resolver of your own is needed only for lists queried without a keyed service: Spamhaus and most other lists refuse queries forwarded by public resolvers such as 8.8.8.8. Spamhaus's Data Query Service, with its key in the zone, works through any resolver, so with it, or with no lists, skip the resolver. See [DNS lists](dns-lists.md).

To run one, add it as another accessory, such as the maintained `klutchell/unbound` pinned to a version, and name it in `nameservers`: `[ <service>-unbound ]` under Kamal, `[ unbound ]` in Compose. It needs no fixed address. mailscore looks the name up through Docker's DNS at boot, and stops if it doesn't resolve, then again every `nameservers_refresh` seconds, 300 by default, so a resolver that comes back on a new address is picked up. A lookup that fails keeps the last addresses and logs a warning. Each worker keeps its own list and refreshes it in the background, so a scan never waits on it. `nameservers` takes addresses too, which are used as they are.

## Verify an accessory

### Before you deploy

Print the command that Kamal runs. `kamal config` prints the merged configuration, not the command.

```sh
bundle exec ruby -rkamal -e '
  config = Kamal::Configuration.create_from(
    config_file: Pathname.new("config/deploy.yml"), destination: "production", version: "check")
  puts Kamal::Commands::Accessory.new(config, name: :mailscore).run.flatten.join(" ")
'
```

On that line, check:

- every flag in the two tables above, with `--tmpfs "/tmp:rw,nosuid,nodev,noexec,size=..."` as one value;
- `--volume mailscore:/data`, and the config mounted at `/etc/mailscore.yml` if you have one;
- `--network` once;
- no `--publish`.

### After you deploy

Read the flags on the running container, and its health:

```sh
docker inspect <container> --format '{{json .HostConfig}}' | jq '{
  NetworkMode, ReadonlyRootfs, CapDrop, SecurityOpt, PidsLimit, Memory, MemorySwap, Tmpfs, Binds
}'
docker inspect <container> --format '{{json .State.Health}}' | jq '{Status, FailingStreak}'
```

The health check is the image's own, so `Status` turns `healthy` within a minute of the start.

## Learned text

With `fasttext` on, the database keeps the words of every message learned as spam or ham, its Subject and text up to 1,000 words and 16 KB, in `fasttext_samples`, to train the model on. That is message content: treat the volume and its backups as mail. A sample goes after `fasttext_sample_expiry`, 90 days by default, and each class keeps at most `fasttext_max_samples`. Mail that is only scanned leaves no text. With `fasttext` off nothing is kept.

## Health

The image checks `GET /ping` every 30 seconds, with no token. It assumes `port: 8080` and a `bind` that takes 127.0.0.1, as the default 0.0.0.0 does: if you set another `port`, or `bind` to one address, override the health check too. `GET /health` with a token also checks the database.
