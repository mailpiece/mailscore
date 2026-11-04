# Changelog

## Unreleased

- `dnsbl: rspamd` and `uribl: rspamd` ask the DNS lists Rspamd asks by default
- Each DNS list is probed as Rspamd's monitored check does and skipped while it lists its probe

## 0.1.1

- `/check` returns each symbol's description; descriptions are short labels

## 0.1.0

- First release: a spam scoring daemon over HTTP
