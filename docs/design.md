<!-- SPDX-License-Identifier: LGPL-3.0-only -->
<!-- SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev> -->

# Design

## Scope

The deck is a client for the Proxmox™ VE HTTP API (`/api2/json`, port 8006):
nodes, guests (QEMU™ VMs and LXC containers), power actions, snapshots,
clones, backups and restores, storage contents, tasks, cloud-init, pools,
HA, the firewall, users and ACLs. `get`, `post`, `put` and `delete` (over
`call`) reach any other endpoint. It needs the `net` capability and runs on
the default binary only.

Not covered: endpoints without a typed verb are reached through `call`
with the JSON readers; the deck has no websocket support (the VNC and
terminal consoles) and no client for a Proxmox Backup Server host itself,
whose volumes it restores through Proxmox VE.

## Decisions

- **A deck for one vendor.** Proxmox VE has a documented REST and JSON API
  with header-based token auth, so the deck is a thin, typed layer over
  `http` rather than a generic REST client.
- **Two credentials, mutually exclusive.** `withToken` sends
  `Authorization: PVEAPIToken=<id>=<secret>` and needs no CSRF token or
  renewal. `withTicket`, `login` and `loginTotp` use the `PVEAuthCookie`
  ticket plus the `CSRFPreventionToken` header on writes. Setting one
  clears the other. `renew` posts the current ticket as the password, and
  `fresh` renews a ticket older than half of `TICKET_LIFETIME` (7200 s) and
  fails once it has expired, reading the issue time from the ticket itself.
- **One request path.** `call` puts GET and DELETE parameters in the query
  and sends POST and PUT parameters form-encoded; booleans travel as `"1"`
  and `"0"`. It returns the reply's `data` member, JSON `null` when absent.
  A refused request names Proxmox's reason, from the status line or the
  `message` member, plus each parameter's complaint from `errors`.
- **Address normalization.** `client` accepts a bare host
  (`https://host:8006`), `host:port`, a bare IPv6 address (bracketed) or a
  full URL, and drops a trailing `/` or `/api2/json`.
- **Loose JSON on read.** Proxmox types its JSON loosely (numbers as
  strings, booleans as `1` or `"1"`), so replies are read through tolerant
  helpers that accept each shape instead of the strict `json.as*` readers.
- **Tasks.** Task-starting verbs return the UPID string; a few may return
  `""` when Proxmox finished before answering. `waitTask` polls
  `taskStatus` every `pollMs` (1000 by default, also when a `Client` was
  declared without `client` and has 0).
- **Retries.** Writes are never retried: they need not be idempotent.
  `withRetries` lets `http` repeat a GET answered 429 or 5xx. `waitTask`
  repeats a status check after a timeout, a 5xx answer, a status-0 reply
  it cannot use, or a `net.NetError` whose request was never sent, up to `MAX_POLL_FAILURES` in
  a row, then throws the last failure with its kind. A 4xx answer is final
  (a bad credential does not heal by waiting), and so is a connection lost
  after the request was sent (a sent `net.NetError` or kind `"closed"`).
  A malformed UPID is refused before the first check.
- **Guests.** `guests` lists `/cluster/resources?type=vm` sorted by vmid;
  `guest` and `guestByName` filter it, and `guestByName` fails on a
  duplicate name rather than picking one.
- **Argument checks before sending.** `create` refuses a `vmid` inside its
  parameters (it is an argument), `createContainer` requires `ostemplate`,
  and `restore` chooses QEMU or LXC from the archive name, Proxmox Backup
  Server volume ids included. Cloud-init SSH keys are percent-encoded once
  more, as Proxmox expects inside the form.

## Errors

Every failure of kind `"proxmox"` (`ERROR_KIND`) is a `ProxmoxError` with
`status`, the HTTP status the API answered. 0 means the deck raised it
itself: a local check (refused input, no such guest, a malformed UPID,
`waitTask` out of time, an expired ticket), a 2xx reply it cannot use, or
an `http` failure of a non-generic kind. Network failures never carry
status 0; they are `net.NetError` (kind `"net"`). Messages start with `proxmox: ` and name the request:
`proxmox: <verb> <path>: HTTP <status>: <reason>`. `waitTask` reads
`status`, never the message, to decide whether to retry.

Generic kinds:

- a reply over `http`'s size cap stays kind `"limit"`, with the request in
  front of the message; a JSON reply past the decoder's nesting or node cap
  is kind `"limit"` too;
- a reply that does not come in time is kind `"timeout"`, a connection
  closed mid-reply `"closed"`, passed on unchanged;
- a host that cannot be reached (refused, reset, unreachable, no DNS answer,
  a failed TLS handshake, closed before any reply) is the `net.NetError`
  (kind `"net"`) that `http` raised, passed on unchanged, so `reason`,
  `op`, `sent` and `replied` stay readable;
- a cancelled task goes on as it is.


## Security and limits

- API paths are checked before anything is sent: `..`, `?`, `#`, `//`, CR
  and LF are refused, so a path cannot send the credential to another
  endpoint or host. Query parameters go in `params`, never in the path.
- `withTicket` refuses `;`, `,`, whitespace and control characters, because
  the ticket travels in a cookie.
- The `Client` holds the credential in plain text; `describe` is the form
  to log and never shows a secret.
- Certificates are checked by default. A self-signed Proxmox host is
  trusted with `withCaCert`; `withInsecure` turns checking off. The deck
  does not refuse a plain `http://` URL the caller passes explicitly.
- Reply sizes are bounded by `http`'s default cap; the idle timeout is
  `http`'s default unless `withTimeout` sets one.

## Testing and validation

- `src/proxmox_test.j` runs every verb against a loopback `httpd` fake that
  answers canned Proxmox replies in order and records what it received
  (method, path, query, token, cookie, CSRF header, content type, body), so
  the tests check both the requests and the reading of replies.
- Ticket age and renewal are tested with tickets built at a chosen age;
  `waitTask` with a short poll interval, including outages, refusals and
  giving up.
- Transport failures are tested against a closed loopback port and a
  listener that closes without answering.
- The examples need a Proxmox host and a credential, so the gate only
  parses them.

Not covered: the replies are modelled on the API documentation, not
recorded from a live Proxmox VE host, and no automated test runs against
one.

## Known limitations and open questions

- A VM's network interfaces need the QEMU guest agent; without it Proxmox
  answers HTTP 500.
- A timeout during a write is kind `"timeout"`; the caller cannot tell from
  it whether the write took effect.

## Dependencies on the interpreter

- The bundled `http` and `uri` modules; `http`'s retry options for GETs.
- Thrown error structs and lint's L104 for `ProxmoxError`.
- `net.NetError` and the `"net"` kind (`jennifer`'s M28.65, transport
  errors have their own kind).
- Floor `>=0.27.0`: the tests use the UTF-8 codecs of `encoding.encode` /
  `decode` and `strings.replicate`, new in 0.27.0.
