# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev>
# pragma-jennifer-version: >=0.25.0
# pragma-jennifer-capability: net

/**
 * A client for the Proxmox VE API (`/api2/json`).
 *
 * A thin client: `get`, `post`, `put` and `delete` reach any endpoint and
 * return the reply's `data` member as a `json.Value`. A handful of typed
 * verbs cover the daily work: nodes, guests (QEMU VMs and LXC containers),
 * power actions, snapshots, storage and tasks.
 *
 * A `Client` authenticates with an API token (`withToken`) or with a ticket
 * from `login`. Proxmox hosts usually present a self-signed certificate:
 * trust it with `withCaCert`, or turn checking off with `withInsecure`.
 * Every failure is `Error{kind: "proxmox"}`.
 *
 * @module proxmox
 * @see https://pve.proxmox.com/pve-docs/api-viewer/
 * @example
 *   def c as proxmox.Client init proxmox.client("pve.example.com");
 *   $c = proxmox.withToken($c, "root@pam!automation", "8d3f...");
 *   for (def g in proxmox.guests($c)) {
 *       io.printf("%d %s %s\n", $g.vmid, $g.name, $g.status);
 *   }
 */
use convert;
use json;
use lists;
use maps;
use regex;
use strings;
use time;
import "http.j" as http;
import "uri.j" as uri;

/** The `kind` of every error the deck throws. */
export def const ERROR_KIND as string init "proxmox";

/** Failed status checks in a row after which `waitTask` gives up. */
export def const MAX_POLL_FAILURES as int init 5;

/** Seconds a ticket is valid; Proxmox's fixed lifetime. */
export def const TICKET_LIFETIME as int init 7200;

/** The port the Proxmox VE API listens on. */
export def const DEFAULT_PORT as int init 8006;

/**
 * A connection to one Proxmox VE host or cluster. Build it with `client` and
 * the `with*` functions; each returns a changed copy. Its fields hold the
 * credential in plain text: log `describe($c)`, never the client.
 *
 * @field url {string} base URL, `https://host:8006`, no trailing slash
 * @field tokenId {string} API token id, `user@realm!name`; "" for none
 * @field secret {string} API token secret
 * @field ticket {string} ticket from `login`; "" for none
 * @field csrf {string} the CSRF prevention token that came with the ticket
 * @field tls {http.TlsOptions} certificate checking
 * @field timeoutMs {int} idle timeout per request in milliseconds; 0 for the `http` default
 * @field retries {int} retries of a GET answered 429 or 5xx
 * @field pollMs {int} interval between task status checks in `waitTask`
 */
export def struct Client {
    url as string,
    tokenId as string,
    secret as string,
    ticket as string,
    csrf as string,
    tls as http.TlsOptions,
    timeoutMs as int,
    retries as int,
    pollMs as int
};

/**
 * The version of the Proxmox VE API.
 *
 * @field version {string} e.g. `8.2.4`
 * @field release {string} e.g. `8.2`
 * @field repoid {string} the build's repository id
 */
export def struct Version {
    version as string,
    release as string,
    repoid as string
};

/**
 * A cluster node.
 *
 * @field node {string} node name
 * @field status {string} `online`, `offline` or `unknown`
 * @field cpu {float} CPU load, 0 to 1
 * @field maxcpu {int} CPU count
 * @field mem {int} memory in use, bytes
 * @field maxmem {int} memory, bytes
 * @field uptime {int} seconds
 */
export def struct Node {
    node as string,
    status as string,
    cpu as float,
    maxcpu as int,
    mem as int,
    maxmem as int,
    uptime as int
};

/**
 * A QEMU virtual machine or an LXC container.
 *
 * @field vmid {int} guest id, unique in the cluster
 * @field name {string} guest name
 * @field node {string} the node it lives on
 * @field kind {string} `qemu` or `lxc`
 * @field status {string} `running`, `stopped`, ...
 * @field template {bool} whether it is a template
 * @field cpu {float} CPU load, 0 to 1
 * @field maxcpu {int} virtual CPUs
 * @field mem {int} memory in use, bytes
 * @field maxmem {int} memory, bytes
 * @field disk {int} root disk in use, bytes (containers only)
 * @field maxdisk {int} root disk size, bytes
 * @field uptime {int} seconds
 * @field tags {list of string} the guest's tags
 */
export def struct Guest {
    vmid as int,
    name as string,
    node as string,
    kind as string,
    status as string,
    template as bool,
    cpu as float,
    maxcpu as int,
    mem as int,
    maxmem as int,
    disk as int,
    maxdisk as int,
    uptime as int,
    tags as list of string
};

/**
 * A snapshot of a guest. The list from `snapshots` ends with `current`, the
 * running state.
 *
 * @field name {string} snapshot name
 * @field description {string} its description
 * @field parent {string} the snapshot it was taken after; "" for the first
 * @field snaptime {int} Unix time it was taken; 0 for `current`
 * @field vmstate {bool} whether it holds the RAM of a running VM
 */
export def struct Snapshot {
    name as string,
    description as string,
    parent as string,
    snaptime as int,
    vmstate as bool
};

/**
 * A storage as one node sees it.
 *
 * @field storage {string} storage id
 * @field type {string} `dir`, `lvmthin`, `zfspool`, `nfs`, ...
 * @field content {list of string} what it holds: `images`, `iso`, `backup`, ...
 * @field active {bool} whether it is usable now
 * @field enabled {bool} whether it is enabled
 * @field shared {bool} whether every node sees the same storage
 * @field total {int} size, bytes
 * @field used {int} bytes in use
 * @field avail {int} bytes free
 */
export def struct Storage {
    storage as string,
    type as string,
    content as list of string,
    active as bool,
    enabled as bool,
    shared as bool,
    total as int,
    used as int,
    avail as int
};

/**
 * A background task. Actions such as `start` or `snapshot` return its UPID;
 * `taskStatus` and `waitTask` follow it.
 *
 * @field upid {string} the task's id
 * @field node {string} node it runs on
 * @field type {string} e.g. `qmstart`, `vzdump`
 * @field id {string} what it works on, often the guest id
 * @field user {string} who started it
 * @field status {string} `running` or `stopped`; "" when only parsed from the UPID
 * @field exitStatus {string} `OK`, or the error, once stopped
 */
export def struct Task {
    upid as string,
    node as string,
    type as string,
    id as string,
    user as string,
    status as string,
    exitStatus as string
};

/**
 * A network interface a guest reports.
 *
 * @field name {string} interface name, e.g. `eth0`, `ens18`
 * @field mac {string} hardware address
 * @field addresses {list of string} addresses with prefix, e.g. `10.0.0.5/24`
 */
export def struct Interface {
    name as string,
    mac as string,
    addresses as list of string
};

/**
 * A volume on a storage: a disk image, an ISO, a container template or a
 * backup.
 *
 * @field volid {string} volume id, `<storage>:<path>`
 * @field content {string} `images`, `rootdir`, `iso`, `vztmpl` or `backup`
 * @field format {string} e.g. `raw`, `qcow2`, `iso`, `tar.zst`, `vma.zst`
 * @field size {int} bytes
 * @field ctime {int} Unix time it was created; 0 when unknown
 * @field vmid {int} the guest it belongs to; 0 for none
 * @field notes {string} a backup's notes
 */
export def struct Volume {
    volid as string,
    content as string,
    format as string,
    size as int,
    ctime as int,
    vmid as int,
    notes as string
};

/**
 * A container appliance template that `downloadAppliance` can fetch.
 *
 * @field template {string} file name, e.g. `debian-12-standard_12.7-1_amd64.tar.zst`
 * @field section {string} `system`, `turnkeylinux`, `mail`
 * @field os {string} e.g. `debian-12`
 * @field version {string} template version
 * @field headline {string} one-line description
 */
export def struct Appliance {
    template as string,
    section as string,
    os as string,
    version as string,
    headline as string
};

/**
 * Cloud-init settings for a VM with a cloud-init drive. Empty fields are
 * left as they are.
 *
 * @field user {string} the user to create
 * @field password {string} its password
 * @field sshKeys {list of string} public keys, one per entry
 * @field ipConfig {list of string} per NIC, e.g. `ip=dhcp` or
 *   `ip=10.0.0.5/24,gw=10.0.0.1`; entry 0 is `ipconfig0`
 * @field nameserver {string} DNS servers, space-separated
 * @field searchDomain {string} DNS search domain
 */
export def struct CloudInit {
    user as string,
    password as string,
    sshKeys as list of string,
    ipConfig as list of string,
    nameserver as string,
    searchDomain as string
};

/**
 * A resource pool.
 *
 * @field poolid {string} pool id
 * @field comment {string} its comment
 */
export def struct Pool {
    poolid as string,
    comment as string
};

/**
 * A guest under high availability.
 *
 * @field sid {string} `vm:<vmid>` or `ct:<vmid>`
 * @field state {string} `started`, `stopped`, `disabled` or `ignored`
 * @field group {string} the HA group; "" for none
 */
export def struct HaResource {
    sid as string,
    state as string,
    group as string
};

/**
 * A firewall rule of a guest.
 *
 * @field pos {int} position, 0 first
 * @field type {string} `in`, `out` or `group`
 * @field action {string} `ACCEPT`, `DROP`, `REJECT`, or a security group
 * @field enable {bool} whether it is active
 * @field source {string} source address or alias; "" for any
 * @field dest {string} destination address or alias; "" for any
 * @field proto {string} e.g. `tcp`, `udp`, `icmp`; "" for any
 * @field dport {string} destination port or range
 * @field macro {string} a predefined service, e.g. `SSH`; "" for none
 * @field comment {string} its comment
 */
export def struct FirewallRule {
    pos as int,
    type as string,
    action as string,
    enable as bool,
    source as string,
    dest as string,
    proto as string,
    dport as string,
    macro as string,
    comment as string
};

/**
 * A user account.
 *
 * @field userid {string} `user@realm`
 * @field enabled {bool} whether it may log in
 * @field expire {int} Unix time it expires; 0 for never
 * @field firstname {string} first name
 * @field lastname {string} last name
 * @field email {string} e-mail address
 * @field comment {string} its comment
 */
export def struct User {
    userid as string,
    enabled as bool,
    expire as int,
    firstname as string,
    lastname as string,
    email as string,
    comment as string
};

/**
 * One permission: a role on a path for a user, group or token.
 *
 * @field path {string} e.g. `/`, `/vms/101`, `/pool/lab`, `/storage/local`
 * @field type {string} `user`, `group` or `token`
 * @field ugid {string} the user, group or token id
 * @field roleid {string} e.g. `PVEVMUser`, `PVEAdmin`
 * @field propagate {bool} whether it applies below the path
 */
export def struct Acl {
    path as string,
    type as string,
    ugid as string,
    roleid as string,
    propagate as bool
};

/**
 * Raise a deck error.
 *
 * @param message {string} what went wrong
 * @throws {Error} always, with `kind` `"proxmox"`
 */
func fail(message as string) {
    throw Error{kind: ERROR_KIND, message: "proxmox: " + $message};
}

/**
 * The base URL for a host name or URL. A bare host gets `https://` and port
 * 8006; a trailing slash and a trailing `/api2/json` are dropped.
 *
 * @param address {string} `pve.example.com`, `10.0.0.5:8006` or `https://pve:8006/`
 * @return {string} `https://host:port`
 */
func baseUrl(address as string) {
    def url as string init strings.trim($address);
    if ($url == "") {
        fail("the host is empty");
    }
    while (strings.endsWith($url, "/")) {
        $url = strings.substring($url, 0, len($url) - 1);
    }
    if (strings.endsWith($url, "/api2/json")) {
        $url = strings.substring($url, 0, len($url) - len("/api2/json"));
    }
    if (strings.contains($url, "://")) {
        return $url;
    }
    if (not strings.startsWith($url, "[") and
        strings.indexOf($url, ":") != strings.lastIndexOf($url, ":")) {
        $url = "[" + $url + "]";
    }
    if (strings.contains($url, ":") and not strings.startsWith($url, "[")) {
        return "https://" + $url;
    }
    if (strings.startsWith($url, "[") and strings.contains($url, "]:")) {
        return "https://" + $url;
    }
    return "https://" + $url + ":" + convert.toString(DEFAULT_PORT);
}

/**
 * A client for a host, with no credentials yet.
 *
 * @param address {string} host name, `host:port` or a full `https://` URL
 * @return {Client} the client; full certificate checking, 1 s task polling
 * @throws {Error} kind `"proxmox"` when the address is empty
 */
export func client(address as string) {
    def c as Client;
    $c.url = baseUrl($address);
    $c.pollMs = 1000;
    return $c;
}

/**
 * Authenticate with an API token. Token requests need no CSRF token and no
 * renewal.
 *
 * @param c {Client} the client
 * @param tokenId {string} `user@realm!name`
 * @param secret {string} the token's secret (a UUID)
 * @return {Client} the changed copy
 * @throws {Error} kind `"proxmox"` when the id is not `user@realm!name`
 */
export func withToken(c as Client, tokenId as string, secret as string) {
    if (not strings.contains($tokenId, "@") or not strings.contains($tokenId, "!")) {
        fail("a token id is user@realm!name, got \"" + $tokenId + "\"");
    }
    $c.tokenId = $tokenId;
    $c.secret = $secret;
    $c.ticket = "";
    $c.csrf = "";
    return $c;
}

/**
 * Use a ticket from an earlier `login`, for example one kept in a file.
 *
 * @param c {Client} the client
 * @param ticket {string} the `PVEAuthCookie` value
 * @param csrf {string} the matching `CSRFPreventionToken`
 * @return {Client} the changed copy
 * @throws {Error} kind `"proxmox"` when the ticket holds `;`, `,`, spaces or
 *   control characters, which cannot travel in a cookie
 */
export func withTicket(c as Client, ticket as string, csrf as string) {
    if (regex.matches("[;,\\s\\x00-\\x1f\\x7f]", $ticket)) {
        fail("a ticket holds no separators, spaces or control characters");
    }
    $c.ticket = $ticket;
    $c.csrf = $csrf;
    $c.tokenId = "";
    $c.secret = "";
    return $c;
}

/**
 * Trust a certificate (PEM) in addition to the system's, such as the
 * cluster's `pve-root-ca.pem`.
 *
 * @param c {Client} the client
 * @param pem {bytes} the certificate
 * @return {Client} the changed copy
 */
export func withCaCert(c as Client, pem as bytes) {
    $c.tls.caCert = $pem;
    $c.tls.skipVerify = false;
    return $c;
}

/**
 * Accept any certificate. The connection is still encrypted but no longer
 * authenticated; prefer `withCaCert`.
 *
 * @param c {Client} the client
 * @return {Client} the changed copy
 */
export func withInsecure(c as Client) {
    $c.tls.skipVerify = true;
    return $c;
}

/**
 * Set the idle timeout of each request.
 *
 * @param c {Client} the client
 * @param ms {int} milliseconds; 0 for the `http` default
 * @return {Client} the changed copy
 */
export func withTimeout(c as Client, ms as int) {
    $c.timeoutMs = $ms;
    return $c;
}

/**
 * Retry a GET answered 429 or 5xx. Writes are never retried: they need not
 * be idempotent.
 *
 * @param c {Client} the client
 * @param n {int} retries, 0 for none
 * @return {Client} the changed copy
 */
export func withRetries(c as Client, n as int) {
    $c.retries = $n;
    return $c;
}

/**
 * Set how often `waitTask` asks for a task's status.
 *
 * @param c {Client} the client
 * @param ms {int} milliseconds between checks
 * @return {Client} the changed copy
 */
export func withPollInterval(c as Client, ms as int) {
    $c.pollMs = $ms;
    return $c;
}

/**
 * Log in with a user name and password and keep the ticket. A ticket lasts
 * two hours; `login` again, or call `renew`, before it runs out.
 *
 * @param c {Client} the client
 * @param username {string} `user@realm`, e.g. `root@pam`
 * @param password {string} the password
 * @return {Client} the copy holding the ticket
 * @throws {Error} kind `"proxmox"` when the login is refused, or when the
 *   account needs a second factor (use `loginTotp`)
 */
export func login(c as Client, username as string, password as string) {
    def data as json.Value init ticketRequest($c, {"username": $username, "password": $password});
    if (field($data, "/NeedTFA") != "") {
        fail("the account " + $username + " needs a second factor: use loginTotp");
    }
    return keepTicket($c, $data);
}

/**
 * Log in to an account with a TOTP second factor.
 *
 * @param c {Client} the client
 * @param username {string} `user@realm`
 * @param password {string} the password
 * @param code {string} the current six-digit code
 * @return {Client} the copy holding the ticket
 * @throws {Error} kind `"proxmox"` when either step is refused
 */
export func loginTotp(c as Client, username as string, password as string, code as string) {
    def first as json.Value init ticketRequest($c, {"username": $username, "password": $password});
    if (field($first, "/NeedTFA") == "") {
        return keepTicket($c, $first);
    }
    def params as map of string to string init {
        "username": $username,
        "tfa-challenge": field($first, "/ticket"),
        "password": "totp:" + $code
    };
    return keepTicket($c, ticketRequest($c, $params));
}

/**
 * Exchange the ticket for a fresh one, two more hours.
 *
 * @param c {Client} a client holding a ticket that has not run out
 * @return {Client} the copy holding the new ticket
 * @throws {Error} kind `"proxmox"` when the client has no ticket or it was refused
 */
export func renew(c as Client) {
    if ($c.ticket == "") {
        fail("renew needs a ticket from login");
    }
    def user as string init ticketUser($c.ticket);
    return keepTicket($c, ticketRequest($c, {"username": $user, "password": $c.ticket}));
}

/**
 * The user name a ticket was issued to: `PVE:root@pam:...` gives `root@pam`.
 *
 * @param ticket {string} the ticket
 * @return {string} the user, "" when the ticket has another shape
 */
func ticketUser(ticket as string) {
    def parts as list of string init strings.split($ticket, ":");
    if (len($parts) < 3) {
        return "";
    }
    return $parts[1];
}

/**
 * POST to `/access/ticket` without credentials.
 *
 * @param c {Client} the client
 * @param params {map of string to string} the form fields
 * @return {json.Value} the reply's `data`
 */
func ticketRequest(c as Client, params as map of string to string) {
    def anon as Client init $c;
    $anon.tokenId = "";
    $anon.secret = "";
    $anon.ticket = "";
    $anon.csrf = "";
    return call($anon, "POST", "/access/ticket", $params);
}

/**
 * Keep the ticket and CSRF token of a `/access/ticket` reply.
 *
 * @param c {Client} the client
 * @param data {json.Value} the reply's `data`
 * @return {Client} the changed copy
 */
func keepTicket(c as Client, data as json.Value) {
    def ticket as string init field($data, "/ticket");
    if ($ticket == "") {
        fail("the login reply holds no ticket");
    }
    return withTicket($c, $ticket, field($data, "/CSRFPreventionToken"));
}

/**
 * Refuse a path that could send the credential somewhere else.
 *
 * @param path {string} an API path such as `/nodes`
 * @throws {Error} kind `"proxmox"` unless the path starts with one `/` and has
 *   no `..`, `?`, `#` or `//`
 */
func ensurePath(path as string) {
    if (not strings.startsWith($path, "/")) {
        fail("an API path starts with /, got \"" + $path + "\"");
    }
    for (def bad in ["..", "?", "#", "//", "\r", "\n"]) {
        if (strings.contains($path, $bad)) {
            fail("an API path holds no \"" + $bad + "\": " + $path);
        }
    }
}

/**
 * The headers that carry the client's credential.
 *
 * @param c {Client} the client
 * @param method {string} the HTTP method; writes with a ticket add the CSRF token
 * @return {map of string to string} the headers
 */
func authHeaders(c as Client, method as string) {
    def headers as map of string to string init {"Accept": "application/json"};
    if ($c.tokenId != "") {
        $headers["Authorization"] = "PVEAPIToken=" + $c.tokenId + "=" + $c.secret;
    } elseif ($c.ticket != "") {
        $headers["Cookie"] = "PVEAuthCookie=" + $c.ticket;
        if ($method != "GET") {
            $headers["CSRFPreventionToken"] = $c.csrf;
        }
    }
    return $headers;
}

/**
 * Call any endpoint. GET and DELETE send the parameters in the query
 * string, POST and PUT as a form. Pass booleans as `"1"` and `"0"`.
 *
 * @param c {Client} the client
 * @param method {string} `GET`, `POST`, `PUT` or `DELETE`
 * @param path {string} the path under `/api2/json`, e.g. `/nodes/pve1/qemu`
 * @param params {map of string to string} the parameters; `{}` for none
 * @return {json.Value} the reply's `data` member; JSON `null` for none
 * @throws {Error} kind `"proxmox"` on a bad path, a network failure or a reply
 *   that is not 2xx; the message names the status and Proxmox's reason
 */
export func call(c as Client, method as string, path as string, params as map of string to string) {
    def verb as string init strings.upper($method);
    if ($verb != "GET" and $verb != "POST" and $verb != "PUT" and $verb != "DELETE") {
        fail("unsupported method " + $method);
    }
    ensurePath($path);
    def url as string init $c.url + "/api2/json" + $path;
    def body as string init "";
    def headers as map of string to string init authHeaders($c, $verb);
    def query as string init uri.buildQuery($params);
    if ($verb == "GET" or $verb == "DELETE") {
        if ($query != "") {
            $url = $url + "?" + $query;
        }
    } else {
        $body = $query;
        $headers["Content-Type"] = "application/x-www-form-urlencoded";
    }
    def o as http.Options;
    $o.tls = $c.tls;
    $o.timeoutMs = $c.timeoutMs;
    if ($verb == "GET") {
        $o.maxRetries = $c.retries;
        $o.backoffMs = 500;
    }
    def r as http.Response;
    try {
        $r = http.send($verb, $url, $headers, $body, $o);
    } catch (e) {
        fail($verb + " " + $path + ": " + $e.message);
    }
    if ($r.status < 200 or $r.status >= 300) {
        fail($verb + " " + $path + ": " + failureText($r));
    }
    return dataOf($r.body, $verb + " " + $path);
}

/**
 * GET an endpoint.
 *
 * @param c {Client} the client
 * @param path {string} the path under `/api2/json`
 * @param params {map of string to string} query parameters; `{}` for none
 * @return {json.Value} the reply's `data`
 * @throws {Error} kind `"proxmox"` as `call`
 */
export func get(c as Client, path as string, params as map of string to string) {
    return call($c, "GET", $path, $params);
}

/**
 * POST to an endpoint. Actions that start a task return its UPID as a
 * string node.
 *
 * @param c {Client} the client
 * @param path {string} the path under `/api2/json`
 * @param params {map of string to string} form fields; `{}` for none
 * @return {json.Value} the reply's `data`
 * @throws {Error} kind `"proxmox"` as `call`
 */
export func post(c as Client, path as string, params as map of string to string) {
    return call($c, "POST", $path, $params);
}

/**
 * PUT to an endpoint.
 *
 * @param c {Client} the client
 * @param path {string} the path under `/api2/json`
 * @param params {map of string to string} form fields; `{}` for none
 * @return {json.Value} the reply's `data`
 * @throws {Error} kind `"proxmox"` as `call`
 */
export func put(c as Client, path as string, params as map of string to string) {
    return call($c, "PUT", $path, $params);
}

/**
 * DELETE an endpoint.
 *
 * @param c {Client} the client
 * @param path {string} the path under `/api2/json`
 * @param params {map of string to string} query parameters; `{}` for none
 * @return {json.Value} the reply's `data`
 * @throws {Error} kind `"proxmox"` as `call`
 */
export func delete(c as Client, path as string, params as map of string to string) {
    return call($c, "DELETE", $path, $params);
}

/**
 * The `data` member of a reply body.
 *
 * @param body {string} the body
 * @param what {string} the request, for the error message
 * @return {json.Value} `data`, JSON `null` when the body or the member is absent
 */
func dataOf(body as string, what as string) {
    if (strings.trim($body) == "") {
        return json.decode("null");
    }
    def doc as json.Value;
    try {
        $doc = json.decode($body);
    } catch (e) {
        fail($what + ": the reply is not JSON");
    }
    if (json.typeOf($doc) != "map" or not json.has($doc, "/data")) {
        return json.decode("null");
    }
    return json.get($doc, "/data");
}

/**
 * Explain a refused request. Proxmox puts its reason in the status line;
 * newer versions repeat it as `message`, and a parameter check adds
 * `errors`, one entry per parameter.
 *
 * @param r {http.Response} the reply
 * @return {string} `HTTP <status>: <reason>`, with the parameter errors
 */
func failureText(r as http.Response) {
    def text as string init "HTTP " + convert.toString($r.status);
    def reason as string init strings.trim($r.statusText);
    def doc as json.Value init json.decode("null");
    try {
        $doc = json.decode($r.body);
    } catch (e) {
        $doc = json.decode("null");
    }
    if (json.typeOf($doc) == "map") {
        def said as string init strings.trim(field($doc, "/message"));
        if ($said != "") {
            $reason = $said;
        }
    }
    if ($reason != "") {
        $text = $text + ": " + $reason;
    }
    if (json.typeOf($doc) == "map" and kindAt($doc, "/errors") == "map") {
        def parts as list of string init [];
        for (def name in json.keys($doc, "/errors")) {
            $parts[] = $name + ": " + strings.trim(field($doc, "/errors/" + pointerToken($name)));
        }
        if (len($parts) > 0) {
            $text = $text + " (" + strings.join($parts, "; ") + ")";
        }
    }
    return $text;
}

/**
 * Escape a map key for a JSON Pointer.
 *
 * @param key {string} the key
 * @return {string} the key with `~` and `/` escaped
 */
func pointerToken(key as string) {
    return strings.replace(strings.replace($key, "~", "~0"), "/", "~1");
}

/**
 * The type of a node, `missing` when the pointer does not resolve. Jennifer
 * 0.25.0's `json.typeOf` throws for a missing member instead.
 *
 * @param v {json.Value} the document
 * @param ptr {string} the pointer; "" for the root
 * @return {string} `null`, `bool`, `int`, `float`, `string`, `list`, `map` or `missing`
 */
func kindAt(v as json.Value, ptr as string) {
    if ($ptr == "") {
        return json.typeOf($v);
    }
    if (not json.has($v, $ptr)) {
        return "missing";
    }
    return json.typeOf($v, $ptr);
}

/**
 * Read a node as text, whatever its type. Proxmox sends numbers as strings
 * in places and strings as numbers in others.
 *
 * @param v {json.Value} the document
 * @param ptr {string} the pointer
 * @return {string} the text; "" for absent or `null`
 */
func field(v as json.Value, ptr as string) {
    def kind as string init kindAt($v, $ptr);
    if ($kind == "string") {
        return json.asString($v, $ptr);
    } elseif ($kind == "int") {
        return convert.toString(json.asInt($v, $ptr));
    } elseif ($kind == "float") {
        return convert.toString(json.asFloat($v, $ptr));
    } elseif ($kind == "bool") {
        if (json.asBool($v, $ptr)) {
            return "1";
        }
        return "0";
    }
    return "";
}

/**
 * Read a node as an int: a number (truncated) or a numeric string.
 *
 * @param v {json.Value} the document
 * @param ptr {string} the pointer
 * @return {int} the number; 0 for absent, `null` or not numeric
 */
func number(v as json.Value, ptr as string) {
    def kind as string init kindAt($v, $ptr);
    if ($kind == "int") {
        return json.asInt($v, $ptr);
    } elseif ($kind == "float") {
        return convert.toInt(json.asFloat($v, $ptr));
    } elseif ($kind == "bool") {
        if (json.asBool($v, $ptr)) {
            return 1;
        }
    } elseif ($kind == "string") {
        try {
            return convert.toInt(strings.trim(json.asString($v, $ptr)));
        } catch (e) {
            return 0;
        }
    }
    return 0;
}

/**
 * Read a node as a float.
 *
 * @param v {json.Value} the document
 * @param ptr {string} the pointer
 * @return {float} the number; 0 for absent, `null` or not numeric
 */
func real(v as json.Value, ptr as string) {
    def kind as string init kindAt($v, $ptr);
    if ($kind == "int" or $kind == "float") {
        return json.asFloat($v, $ptr);
    } elseif ($kind == "string") {
        try {
            return convert.toFloat(strings.trim(json.asString($v, $ptr)));
        } catch (e) {
            return 0.0;
        }
    }
    return 0.0;
}

/**
 * Read a Proxmox flag: `1`, `true` or `"1"` are true.
 *
 * @param v {json.Value} the document
 * @param ptr {string} the pointer
 * @return {bool} the flag; false for absent
 */
func flag(v as json.Value, ptr as string) {
    def text as string init field($v, $ptr);
    return $text == "1" or $text == "true";
}

/**
 * Split a list Proxmox writes as one string.
 *
 * @param text {string} e.g. `images,rootdir` or `web;prod`
 * @param sep {string} the separator
 * @return {list of string} the non-empty items
 */
func splitList(text as string, sep as string) {
    def out as list of string init [];
    for (def item in strings.split($text, $sep)) {
        def t as string init strings.trim($item);
        if ($t != "") {
            $out[] = $t;
        }
    }
    return $out;
}

/**
 * The pointers of a list's elements.
 *
 * @param v {json.Value} the document
 * @return {list of string} `/0`, `/1`, ...; empty when `v` is not a list
 */
func items(v as json.Value) {
    def out as list of string init [];
    if (json.typeOf($v) != "list") {
        return $out;
    }
    def n as int init json.length($v);
    def i as int init 0;
    while ($i < $n) {
        $out[] = "/" + convert.toString($i);
        $i = $i + 1;
    }
    return $out;
}

/**
 * Sort key of a node.
 *
 * @param n {Node} the node
 * @return {string} its name
 */
func nodeKey(n as Node) {
    return $n.node;
}

/**
 * Sort key of a guest.
 *
 * @param g {Guest} the guest
 * @return {int} its id
 */
func guestKey(g as Guest) {
    return $g.vmid;
}

/**
 * Sort key of a snapshot.
 *
 * @param s {Snapshot} the snapshot
 * @return {int} when it was taken
 */
func snapshotKey(s as Snapshot) {
    return $s.snaptime;
}

/**
 * Sort key of a storage.
 *
 * @param s {Storage} the storage
 * @return {string} its id
 */
func storageKey(s as Storage) {
    return $s.storage;
}

/**
 * The version of the API the client talks to.
 *
 * @param c {Client} the client
 * @return {Version} the version
 * @throws {Error} kind `"proxmox"` as `call`
 */
export func version(c as Client) {
    def d as json.Value init get($c, "/version", {});
    return Version{
        version: field($d, "/version"),
        release: field($d, "/release"),
        repoid: field($d, "/repoid")
    };
}

/**
 * The cluster's nodes, sorted by name.
 *
 * @param c {Client} the client
 * @return {list of Node} the nodes
 * @throws {Error} kind `"proxmox"` as `call`
 */
export func nodes(c as Client) {
    def d as json.Value init get($c, "/nodes", {});
    def out as list of Node init [];
    for (def p in items($d)) {
        $out[] = Node{
            node: field($d, $p + "/node"),
            status: field($d, $p + "/status"),
            cpu: real($d, $p + "/cpu"),
            maxcpu: number($d, $p + "/maxcpu"),
            mem: number($d, $p + "/mem"),
            maxmem: number($d, $p + "/maxmem"),
            uptime: number($d, $p + "/uptime")
        };
    }
    return lists.sortBy($out, nodeKey);
}

/**
 * Fold one `/cluster/resources` entry of type `qemu` or `lxc`.
 *
 * @param d {json.Value} the document
 * @param p {string} the entry's pointer
 * @return {Guest} the guest
 */
func guestFrom(d as json.Value, p as string) {
    def kind as string init field($d, $p + "/type");
    return Guest{
        vmid: number($d, $p + "/vmid"),
        name: field($d, $p + "/name"),
        node: field($d, $p + "/node"),
        kind: $kind,
        status: field($d, $p + "/status"),
        template: flag($d, $p + "/template"),
        cpu: real($d, $p + "/cpu"),
        maxcpu: number($d, $p + "/maxcpu"),
        mem: number($d, $p + "/mem"),
        maxmem: number($d, $p + "/maxmem"),
        disk: number($d, $p + "/disk"),
        maxdisk: number($d, $p + "/maxdisk"),
        uptime: number($d, $p + "/uptime"),
        tags: splitList(
            strings.replace(strings.replace(field($d, $p + "/tags"), ",", ";"), " ", ";"),
            ";")
    };
}

/**
 * Every VM and container in the cluster, templates included, sorted by id.
 *
 * @param c {Client} the client
 * @return {list of Guest} the guests
 * @throws {Error} kind `"proxmox"` as `call`
 */
export func guests(c as Client) {
    def d as json.Value init get($c, "/cluster/resources", {"type": "vm"});
    def out as list of Guest init [];
    for (def p in items($d)) {
        def kind as string init field($d, $p + "/type");
        if ($kind == "qemu" or $kind == "lxc") {
            $out[] = guestFrom($d, $p);
        }
    }
    return lists.sortBy($out, guestKey);
}

/**
 * One guest, by id.
 *
 * @param c {Client} the client
 * @param vmid {int} the guest id
 * @return {Guest} the guest
 * @throws {Error} kind `"proxmox"` when there is no such guest, or as `call`
 */
export func guest(c as Client, vmid as int) {
    for (def g in guests($c)) {
        if ($g.vmid == $vmid) {
            return $g;
        }
    }
    fail("no guest " + convert.toString($vmid));
}

/**
 * The path of a guest: `/nodes/<node>/<kind>/<vmid>`.
 *
 * @param g {Guest} the guest
 * @return {string} the path
 * @throws {Error} kind `"proxmox"` when the guest has no node or a wrong kind
 */
func guestPath(g as Guest) {
    if ($g.kind != "qemu" and $g.kind != "lxc") {
        fail("a guest is qemu or lxc, got \"" + $g.kind + "\"");
    }
    if ($g.node == "" or $g.vmid <= 0) {
        fail("the guest needs a node and a vmid");
    }
    return "/nodes/" + uri.encode($g.node) + "/" + $g.kind + "/" + convert.toString($g.vmid);
}

/**
 * The live status of a guest: `running`, `stopped`, `paused`, ...
 *
 * @param c {Client} the client
 * @param g {Guest} the guest, from `guests` or `guest`
 * @return {string} the status
 * @throws {Error} kind `"proxmox"` as `call`
 */
export func status(c as Client, g as Guest) {
    def d as json.Value init get($c, guestPath($g) + "/status/current", {});
    def qmp as string init field($d, "/qmpstatus");
    if ($qmp != "") {
        return $qmp;
    }
    return field($d, "/status");
}

/**
 * Run a power action.
 *
 * @param c {Client} the client
 * @param g {Guest} the guest
 * @param action {string} `start`, `stop`, ...
 * @param params {map of string to string} the action's parameters
 * @return {string} the task's UPID
 */
func power(c as Client, g as Guest, action as string, params as map of string to string) {
    return upidOf(post($c, guestPath($g) + "/status/" + $action, $params), $action);
}

/**
 * The UPID a task-starting call returned.
 *
 * @param d {json.Value} the reply's `data`
 * @param what {string} the action, for the error message
 * @return {string} the UPID
 */
func upidOf(d as json.Value, what as string) {
    def upid as string init field($d, "");
    if (not strings.startsWith($upid, "UPID:")) {
        fail($what + " returned no task id");
    }
    return $upid;
}

/**
 * Start a guest.
 *
 * @param c {Client} the client
 * @param g {Guest} the guest
 * @return {string} the task's UPID; `waitTask` follows it
 * @throws {Error} kind `"proxmox"` as `call`
 */
export func start(c as Client, g as Guest) {
    return power($c, $g, "start", {});
}

/**
 * Stop a guest at once, like pulling the plug.
 *
 * @param c {Client} the client
 * @param g {Guest} the guest
 * @return {string} the task's UPID
 * @throws {Error} kind `"proxmox"` as `call`
 */
export func stop(c as Client, g as Guest) {
    return power($c, $g, "stop", {});
}

/**
 * Ask the guest's operating system to shut down (ACPI for a VM).
 *
 * @param c {Client} the client
 * @param g {Guest} the guest
 * @param timeoutSec {int} seconds to wait before giving up; 0 for Proxmox's default
 * @return {string} the task's UPID
 * @throws {Error} kind `"proxmox"` as `call`
 */
export func shutdown(c as Client, g as Guest, timeoutSec as int) {
    def params as map of string to string init {};
    if ($timeoutSec > 0) {
        $params["timeout"] = convert.toString($timeoutSec);
    }
    return power($c, $g, "shutdown", $params);
}

/**
 * Reboot a guest through its operating system.
 *
 * @param c {Client} the client
 * @param g {Guest} the guest
 * @return {string} the task's UPID
 * @throws {Error} kind `"proxmox"` as `call`
 */
export func reboot(c as Client, g as Guest) {
    return power($c, $g, "reboot", {});
}

/**
 * Pause a VM (`suspend`) or freeze a container.
 *
 * @param c {Client} the client
 * @param g {Guest} the guest
 * @return {string} the task's UPID
 * @throws {Error} kind `"proxmox"` as `call`
 */
export func suspend(c as Client, g as Guest) {
    return power($c, $g, "suspend", {});
}

/**
 * Resume a paused VM or a frozen container.
 *
 * @param c {Client} the client
 * @param g {Guest} the guest
 * @return {string} the task's UPID
 * @throws {Error} kind `"proxmox"` as `call`
 */
export func resume(c as Client, g as Guest) {
    return power($c, $g, "resume", {});
}

/**
 * A guest's configuration: disks, network, CPU, memory, options.
 *
 * @param c {Client} the client
 * @param g {Guest} the guest
 * @return {json.Value} the configuration map, Proxmox's keys as they are
 * @throws {Error} kind `"proxmox"` as `call`
 */
export func config(c as Client, g as Guest) {
    return get($c, guestPath($g) + "/config", {});
}

/**
 * Change configuration keys. Remove a key with `{"delete": "key1,key2"}`.
 *
 * @param c {Client} the client
 * @param g {Guest} the guest
 * @param params {map of string to string} the keys to set
 * @return {null} nothing; the change is done when it returns
 * @throws {Error} kind `"proxmox"` as `call`
 */
export func setConfig(c as Client, g as Guest, params as map of string to string) {
    put($c, guestPath($g) + "/config", $params);
    return null;
}

/**
 * The id `/cluster/nextid` offers for a new guest.
 *
 * @param c {Client} the client
 * @return {int} a free id
 * @throws {Error} kind `"proxmox"` as `call`
 */
export func nextId(c as Client) {
    return number(get($c, "/cluster/nextid", {}), "");
}

/**
 * Clone a guest, as a full copy.
 *
 * @param c {Client} the client
 * @param g {Guest} the guest or template to copy
 * @param newid {int} the new guest's id, from `nextId`
 * @param name {string} the new guest's name (its hostname for a container)
 * @return {string} the task's UPID
 * @throws {Error} kind `"proxmox"` as `call`
 */
export func clone(c as Client, g as Guest, newid as int, name as string) {
    return cloneAs($c, $g, $newid, $name, "1");
}

/**
 * Clone a template as a linked clone: the new guest shares the template's
 * disks and stores only its changes, so it is created in seconds. Proxmox
 * allows it for templates on storage with snapshots (LVM-thin, ZFS, Ceph,
 * qcow2 on a directory).
 *
 * @param c {Client} the client
 * @param g {Guest} the template
 * @param newid {int} the new guest's id, from `nextId`
 * @param name {string} the new guest's name (its hostname for a container)
 * @return {string} the task's UPID
 * @throws {Error} kind `"proxmox"` when `g` is not a template, or as `call`
 */
export func linkedClone(c as Client, g as Guest, newid as int, name as string) {
    if (not $g.template) {
        fail("a linked clone needs a template; guest " + convert.toString($g.vmid) + " is none");
    }
    return cloneAs($c, $g, $newid, $name, "0");
}

/**
 * POST a clone request.
 *
 * @param c {Client} the client
 * @param g {Guest} the guest to copy
 * @param newid {int} the new id
 * @param name {string} the new name
 * @param full {string} `"1"` for a full copy, `"0"` for a linked clone
 * @return {string} the task's UPID
 */
func cloneAs(c as Client, g as Guest, newid as int, name as string, full as string) {
    def params as map of string to string init {"newid": convert.toString($newid), "full": $full};
    if ($g.kind == "lxc") {
        $params["hostname"] = $name;
    } else {
        $params["name"] = $name;
    }
    return upidOf(post($c, guestPath($g) + "/clone", $params), "clone");
}

/**
 * Create a guest of one kind on a node.
 *
 * @param c {Client} the client
 * @param node {string} the node
 * @param kind {string} `qemu` or `lxc`
 * @param vmid {int} the new guest's id
 * @param params {map of string to string} the configuration
 * @return {string} the task's UPID
 */
func create(
    c as Client,
    node as string,
    kind as string,
    vmid as int,
    params as map of string to string) {
    if ($node == "" or $vmid <= 0) {
        fail("creating a guest needs a node and a vmid");
    }
    if (maps.has($params, "vmid")) {
        fail("pass the vmid as an argument, not in params");
    }
    $params["vmid"] = convert.toString($vmid);
    def path as string init "/nodes/" + uri.encode($node) + "/" + $kind;
    return upidOf(post($c, $path, $params), "create");
}

/**
 * Create a QEMU virtual machine. `params` is Proxmox's configuration, the
 * same keys `config` returns: `name`, `memory` (MiB), `cores`, `sockets`,
 * `cpu`, `ostype`, `scsihw`, `scsi0` (`<storage>:<GiB>` makes a new disk),
 * `ide2` (`<storage>:iso/<file>,media=cdrom`), `net0`
 * (`virtio,bridge=vmbr0`), `boot`, `agent`, `start` (`"1"` boots it when
 * done) ...
 *
 * @param c {Client} the client
 * @param node {string} the node to create it on
 * @param vmid {int} the new VM's id, from `nextId`
 * @param params {map of string to string} the configuration, without `vmid`
 * @return {string} the task's UPID
 * @throws {Error} kind `"proxmox"` when the node or id is missing, or as `call`
 */
export func createVm(c as Client, node as string, vmid as int, params as map of string to string) {
    return create($c, $node, "qemu", $vmid, $params);
}

/**
 * Create an LXC container. `params` needs at least `ostemplate`
 * (`<storage>:vztmpl/<file>`); the usual others are `hostname`, `memory`
 * (MiB), `cores`, `rootfs` (`<storage>:<GiB>`), `net0`
 * (`name=eth0,bridge=vmbr0,ip=dhcp`), `password` or `ssh-public-keys`,
 * `unprivileged` (`"1"`), `start`.
 *
 * @param c {Client} the client
 * @param node {string} the node to create it on
 * @param vmid {int} the new container's id, from `nextId`
 * @param params {map of string to string} the configuration, without `vmid`
 * @return {string} the task's UPID
 * @throws {Error} kind `"proxmox"` when the node, id or `ostemplate` is missing,
 *   or as `call`
 */
export func createContainer(
    c as Client,
    node as string,
    vmid as int,
    params as map of string to string) {
    if (not maps.has($params, "ostemplate")) {
        fail("a container needs an ostemplate");
    }
    return create($c, $node, "lxc", $vmid, $params);
}

/**
 * Delete a guest and its disks. Proxmox refuses a running guest: stop it
 * first.
 *
 * @param c {Client} the client
 * @param g {Guest} the guest
 * @param purge {bool} also remove it from backup jobs, replication and HA,
 *   and delete disks no configuration refers to
 * @return {string} the task's UPID
 * @throws {Error} kind `"proxmox"` as `call`
 */
export func destroy(c as Client, g as Guest, purge as bool) {
    def params as map of string to string init {};
    if ($purge) {
        $params["purge"] = "1";
        $params["destroy-unreferenced-disks"] = "1";
    }
    return upidOf(delete($c, guestPath($g), $params), "destroy");
}

/**
 * Turn a stopped guest into a template. A template cannot run; clone it.
 *
 * @param c {Client} the client
 * @param g {Guest} the guest
 * @return {string} the task's UPID for a VM; "" for a container, which is
 *   converted before the call returns
 * @throws {Error} kind `"proxmox"` as `call`
 */
export func toTemplate(c as Client, g as Guest) {
    def upid as string init field(post($c, guestPath($g) + "/template", {}), "");
    if ($upid != "" and not strings.startsWith($upid, "UPID:")) {
        fail("toTemplate returned no task id");
    }
    return $upid;
}

/**
 * A guest's snapshots, `current` last.
 *
 * @param c {Client} the client
 * @param g {Guest} the guest
 * @return {list of Snapshot} the snapshots
 * @throws {Error} kind `"proxmox"` as `call`
 */
export func snapshots(c as Client, g as Guest) {
    def d as json.Value init get($c, guestPath($g) + "/snapshot", {});
    def out as list of Snapshot init [];
    def current as list of Snapshot init [];
    for (def p in items($d)) {
        def s as Snapshot init Snapshot{
            name: field($d, $p + "/name"),
            description: field($d, $p + "/description"),
            parent: field($d, $p + "/parent"),
            snaptime: number($d, $p + "/snaptime"),
            vmstate: flag($d, $p + "/vmstate")
        };
        if ($s.name == "current") {
            $current[] = $s;
        } else {
            $out[] = $s;
        }
    }
    $out = lists.sortBy($out, snapshotKey);
    return lists.concat($out, $current);
}

/**
 * Take a snapshot, without the RAM of a running VM.
 *
 * @param c {Client} the client
 * @param g {Guest} the guest
 * @param name {string} snapshot name: a letter, then letters, digits, `-` or `_`
 * @param description {string} a description; "" for none
 * @return {string} the task's UPID
 * @throws {Error} kind `"proxmox"` as `call`
 */
export func snapshot(c as Client, g as Guest, name as string, description as string) {
    def params as map of string to string init {"snapname": $name};
    if ($description != "") {
        $params["description"] = $description;
    }
    return upidOf(post($c, guestPath($g) + "/snapshot", $params), "snapshot");
}

/**
 * Roll a guest back to a snapshot.
 *
 * @param c {Client} the client
 * @param g {Guest} the guest
 * @param name {string} the snapshot
 * @return {string} the task's UPID
 * @throws {Error} kind `"proxmox"` as `call`
 */
export func rollback(c as Client, g as Guest, name as string) {
    def path as string init guestPath($g) + "/snapshot/" + uri.encode($name) + "/rollback";
    return upidOf(post($c, $path, {}), "rollback");
}

/**
 * Delete a snapshot.
 *
 * @param c {Client} the client
 * @param g {Guest} the guest
 * @param name {string} the snapshot
 * @return {string} the task's UPID
 * @throws {Error} kind `"proxmox"` as `call`
 */
export func deleteSnapshot(c as Client, g as Guest, name as string) {
    def path as string init guestPath($g) + "/snapshot/" + uri.encode($name);
    return upidOf(delete($c, $path, {}), "deleteSnapshot");
}

/**
 * The storages a node sees, sorted by id.
 *
 * @param c {Client} the client
 * @param node {string} the node
 * @return {list of Storage} the storages
 * @throws {Error} kind `"proxmox"` as `call`
 */
export func storages(c as Client, node as string) {
    def d as json.Value init get($c, "/nodes/" + uri.encode($node) + "/storage", {});
    def out as list of Storage init [];
    for (def p in items($d)) {
        $out[] = Storage{
            storage: field($d, $p + "/storage"),
            type: field($d, $p + "/type"),
            content: splitList(field($d, $p + "/content"), ","),
            active: flag($d, $p + "/active"),
            enabled: flag($d, $p + "/enabled"),
            shared: flag($d, $p + "/shared"),
            total: number($d, $p + "/total"),
            used: number($d, $p + "/used"),
            avail: number($d, $p + "/avail")
        };
    }
    return lists.sortBy($out, storageKey);
}

/**
 * Read what a UPID says about its task:
 * `UPID:<node>:<pid>:<pstart>:<starttime>:<type>:<id>:<user>:`.
 *
 * @param upid {string} the UPID
 * @return {Task} the task, with `status` and `exitStatus` empty
 * @throws {Error} kind `"proxmox"` when it is not a UPID
 */
export func parseUpid(upid as string) {
    def parts as list of string init strings.split($upid, ":");
    if (len($parts) < 8 or $parts[0] != "UPID") {
        fail("not a UPID: " + $upid);
    }
    return Task{
        upid: $upid,
        node: $parts[1],
        type: $parts[5],
        id: $parts[6],
        user: $parts[7],
        status: "",
        exitStatus: ""
    };
}

/**
 * The path of a task.
 *
 * @param upid {string} the UPID
 * @return {string} `/nodes/<node>/tasks/<upid>`
 */
func taskPath(upid as string) {
    def t as Task init parseUpid($upid);
    return "/nodes/" + uri.encode($t.node) + "/tasks/" + uri.encode($upid);
}

/**
 * Where a task stands now.
 *
 * @param c {Client} the client
 * @param upid {string} the UPID an action returned
 * @return {Task} the task; `status` is `running` or `stopped`
 * @throws {Error} kind `"proxmox"` as `call`
 */
export func taskStatus(c as Client, upid as string) {
    def t as Task init parseUpid($upid);
    def d as json.Value init get($c, taskPath($upid) + "/status", {});
    $t.status = field($d, "/status");
    $t.exitStatus = field($d, "/exitstatus");
    return $t;
}

/**
 * Wait until a task stops, asking every `pollMs` (see `withPollInterval`).
 * A network failure or a 5xx answer is retried, up to `MAX_POLL_FAILURES`
 * times in a row; a 4xx answer is not.
 *
 * @param c {Client} the client
 * @param upid {string} the UPID
 * @param timeoutMs {int} how long to wait; 0 waits for ever
 * @return {Task} the stopped task; it succeeded when `exitStatus` is `OK`
 * @throws {Error} kind `"proxmox"` when the time runs out, after too many
 *   failed checks in a row, or on a 4xx answer
 */
export func waitTask(c as Client, upid as string, timeoutMs as int) {
    def started as time.Time init time.now();
    def failures as int init 0;
    while (true) {
        def t as Task;
        def answered as bool init true;
        try {
            $t = taskStatus($c, $upid);
        } catch (e) {
            $answered = false;
            $failures = retryOrThrow($e, $failures);
        }
        if ($answered) {
            if ($t.status == "stopped") {
                return $t;
            }
            $failures = 0;
        }
        def waited as int init time.milliseconds(time.sub(time.now(), $started));
        if ($timeoutMs > 0 and $waited >= $timeoutMs) {
            fail("task " + $upid + " still running after " + convert.toString($timeoutMs) + " ms");
        }
        time.sleep(time.fromMilliseconds(pollDelay($c)));
    }
}

/**
 * A task's log.
 *
 * @param c {Client} the client
 * @param upid {string} the UPID
 * @return {list of string} the lines, oldest first (Proxmox's first 500)
 * @throws {Error} kind `"proxmox"` as `call`
 */
export func taskLog(c as Client, upid as string) {
    def d as json.Value init get($c, taskPath($upid) + "/log", {"limit": "500"});
    def out as list of string init [];
    for (def p in items($d)) {
        $out[] = field($d, $p + "/t");
    }
    return $out;
}

/**
 * One guest, by name.
 *
 * @param c {Client} the client
 * @param name {string} the exact name
 * @return {Guest} the guest
 * @throws {Error} kind `"proxmox"` when no guest or several guests have the name
 */
export func guestByName(c as Client, name as string) {
    def found as list of Guest init [];
    for (def g in guests($c)) {
        if ($g.name == $name) {
            $found[] = $g;
        }
    }
    if (len($found) == 0) {
        fail("no guest named \"" + $name + "\"");
    }
    if (len($found) > 1) {
        fail(convert.toString(len($found)) + " guests are named \"" + $name + "\"");
    }
    return $found[0];
}

/**
 * The network interfaces a guest reports. A VM answers through the QEMU
 * guest agent, which must be installed and enabled (`agent: 1`); a
 * container answers on its own.
 *
 * @param c {Client} the client
 * @param g {Guest} a running guest
 * @return {list of Interface} the interfaces, loopback included
 * @throws {Error} kind `"proxmox"` as `call`; a VM without a running agent
 *   answers HTTP 500 `QEMU guest agent is not running`
 */
export func interfaces(c as Client, g as Guest) {
    if ($g.kind == "lxc") {
        return containerInterfaces(get($c, guestPath($g) + "/interfaces", {}));
    }
    return agentInterfaces(get($c, guestPath($g) + "/agent/network-get-interfaces", {}));
}

/**
 * Fold a container's `/interfaces` reply.
 *
 * @param d {json.Value} the reply
 * @return {list of Interface} the interfaces
 */
func containerInterfaces(d as json.Value) {
    def out as list of Interface init [];
    for (def p in items($d)) {
        def addrs as list of string init [];
        for (def a in [field($d, $p + "/inet"), field($d, $p + "/inet6")]) {
            if ($a != "") {
                $addrs[] = $a;
            }
        }
        $out[] = Interface{
            name: field($d, $p + "/name"),
            mac: field($d, $p + "/hwaddr"),
            addresses: $addrs
        };
    }
    return $out;
}

/**
 * Fold the guest agent's `network-get-interfaces` reply.
 *
 * @param d {json.Value} the reply
 * @return {list of Interface} the interfaces
 */
func agentInterfaces(d as json.Value) {
    def r as json.Value init getAt($d, "/result");
    def out as list of Interface init [];
    for (def p in items($r)) {
        def addrs as list of string init [];
        def ips as json.Value init getAt($r, $p + "/ip-addresses");
        for (def q in items($ips)) {
            $addrs[] = field($ips, $q + "/ip-address") + "/" + field($ips, $q + "/prefix");
        }
        $out[] = Interface{
            name: field($r, $p + "/name"),
            mac: field($r, $p + "/hardware-address"),
            addresses: $addrs
        };
    }
    return $out;
}

/**
 * The node at a pointer.
 *
 * @param v {json.Value} the document
 * @param ptr {string} the pointer
 * @return {json.Value} the node; JSON `null` when it is missing
 */
func getAt(v as json.Value, ptr as string) {
    if (kindAt($v, $ptr) == "missing") {
        return json.decode("null");
    }
    return json.get($v, $ptr);
}

/**
 * The guest's IP addresses, without loopback and link-local ones and
 * without prefix.
 *
 * @param c {Client} the client
 * @param g {Guest} a running guest
 * @return {list of string} e.g. `["10.0.0.5", "2001:db8::5"]`
 * @throws {Error} kind `"proxmox"` as `interfaces`
 */
export func ipAddresses(c as Client, g as Guest) {
    def out as list of string init [];
    for (def i in interfaces($c, $g)) {
        if ($i.name == "lo") {
            continue;
        }
        for (def a in $i.addresses) {
            def ip as string init strings.split($a, "/")[0];
            def low as string init strings.lower($ip);
            if (strings.startsWith($ip, "127.") or $ip == "::1" or strings.startsWith(
                $low,
                "fe80:")) {
                continue;
            }
            $out[] = $ip;
        }
    }
    return $out;
}

/**
 * Move a guest to another node of the cluster. A running VM moves live with
 * `online`; a running container is stopped, moved and started again.
 *
 * @param c {Client} the client
 * @param g {Guest} the guest
 * @param target {string} the node to move it to
 * @param online {bool} move a running guest; false needs it stopped
 * @return {string} the task's UPID
 * @throws {Error} kind `"proxmox"` as `call`
 */
export func migrate(c as Client, g as Guest, target as string, online as bool) {
    def params as map of string to string init {"target": $target};
    if ($online and $g.kind == "lxc") {
        $params["restart"] = "1";
    } elseif ($online) {
        $params["online"] = "1";
    }
    return upidOf(post($c, guestPath($g) + "/migrate", $params), "migrate");
}

/**
 * Grow a disk. Disks only grow; shrinking is refused.
 *
 * @param c {Client} the client
 * @param g {Guest} the guest
 * @param disk {string} e.g. `scsi0`, `virtio0` for a VM; `rootfs`, `mp0` for a container
 * @param size {string} `+10G` adds 10 GiB, `64G` sets the size; `K`, `M`, `G`, `T`
 * @return {string} the task's UPID; "" when Proxmox resized before answering
 * @throws {Error} kind `"proxmox"` when the size is malformed, or as `call`
 */
export func resizeDisk(c as Client, g as Guest, disk as string, size as string) {
    if (not regex.matches("^\\+?[0-9]+(\\.[0-9]+)?[KMGT]?$", $size)) {
        fail("a disk size is like +10G or 64G, got \"" + $size + "\"");
    }
    def upid as string init field(
        put($c, guestPath($g) + "/resize", {"disk": $disk, "size": $size}),
        "");
    if ($upid != "" and not strings.startsWith($upid, "UPID:")) {
        fail("resizeDisk returned no task id");
    }
    return $upid;
}

/**
 * Back a guest up to a storage with `vzdump`, zstd-compressed.
 *
 * @param c {Client} the client
 * @param g {Guest} the guest
 * @param storage {string} a storage with `backup` content
 * @param mode {string} `snapshot` (no downtime), `suspend` or `stop`
 * @return {string} the task's UPID
 * @throws {Error} kind `"proxmox"` on another mode, or as `call`
 */
export func backup(c as Client, g as Guest, storage as string, mode as string) {
    if (not lists.contains(["snapshot", "suspend", "stop"], $mode)) {
        fail("a backup mode is snapshot, suspend or stop, got \"" + $mode + "\"");
    }
    def params as map of string to string init {
        "vmid": convert.toString($g.vmid),
        "storage": $storage,
        "mode": $mode,
        "compress": "zstd"
    };
    def path as string init "/nodes/" + uri.encode($g.node) + "/vzdump";
    return upidOf(post($c, $path, $params), "backup");
}

/**
 * What a storage holds, as one node sees it, oldest first.
 *
 * @param c {Client} the client
 * @param node {string} the node
 * @param storage {string} the storage
 * @param content {string} `images`, `rootdir`, `iso`, `vztmpl`, `backup`; "" for all
 * @return {list of Volume} the volumes
 * @throws {Error} kind `"proxmox"` as `call`
 */
export func contents(c as Client, node as string, storage as string, content as string) {
    def params as map of string to string init {};
    if ($content != "") {
        $params["content"] = $content;
    }
    def path as string init "/nodes/" + uri.encode($node) + "/storage/" + uri.encode($storage) +
        "/content";
    def d as json.Value init get($c, $path, $params);
    def out as list of Volume init [];
    for (def p in items($d)) {
        $out[] = Volume{
            volid: field($d, $p + "/volid"),
            content: field($d, $p + "/content"),
            format: field($d, $p + "/format"),
            size: number($d, $p + "/size"),
            ctime: number($d, $p + "/ctime"),
            vmid: number($d, $p + "/vmid"),
            notes: field($d, $p + "/notes")
        };
    }
    return lists.sortBy($out, volumeKey);
}

/**
 * Sort key of a volume.
 *
 * @param v {Volume} the volume
 * @return {int} when it was created
 */
func volumeKey(v as Volume) {
    return $v.ctime;
}

/**
 * The backups on a storage: `contents` with `backup`.
 *
 * @param c {Client} the client
 * @param node {string} the node
 * @param storage {string} the storage
 * @return {list of Volume} the backups, oldest first
 * @throws {Error} kind `"proxmox"` as `call`
 */
export func backups(c as Client, node as string, storage as string) {
    return contents($c, $node, $storage, "backup");
}

/**
 * Restore a backup as a new guest, or over a stopped one. The kind follows
 * the archive: `vzdump-qemu-...` or a Proxmox Backup Server `backup/vm/...`
 * makes a VM, `vzdump-lxc-...` or `backup/ct/...` a container.
 *
 * @param c {Client} the client
 * @param node {string} the node to restore on
 * @param vmid {int} the guest id to restore to
 * @param volid {string} the backup, from `backups`
 * @param storage {string} the storage for the disks; "" for the original ones
 * @return {string} the task's UPID
 * @throws {Error} kind `"proxmox"` when the archive is no guest backup, or as `call`
 */
export func restore(c as Client, node as string, vmid as int, volid as string, storage as string) {
    def params as map of string to string init {};
    def kind as string init "";
    def path as string init $volid;
    def colon as int init strings.indexOf($volid, ":");
    if ($colon >= 0) {
        $path = strings.substring($volid, $colon + 1);
    }
    if (strings.contains($path, "vzdump-qemu-") or strings.startsWith($path, "backup/vm/")) {
        $kind = "qemu";
        $params["archive"] = $volid;
    } elseif (strings.contains($path, "vzdump-lxc-") or strings.startsWith($path, "backup/ct/")) {
        $kind = "lxc";
        $params["ostemplate"] = $volid;
        $params["restore"] = "1";
    } else {
        fail("not a backup of a VM or container: " + $volid);
    }
    if ($storage != "") {
        $params["storage"] = $storage;
    }
    return create($c, $node, $kind, $vmid, $params);
}

/**
 * Delete a volume: a backup, an ISO, a template or an unused disk.
 *
 * @param c {Client} the client
 * @param node {string} a node that sees the storage
 * @param volid {string} the volume, `<storage>:<path>`
 * @return {string} the task's UPID; "" when it was deleted before the answer
 * @throws {Error} kind `"proxmox"` when the id has no storage, or as `call`
 */
export func deleteVolume(c as Client, node as string, volid as string) {
    def colon as int init strings.indexOf($volid, ":");
    if ($colon <= 0) {
        fail("a volume id is <storage>:<path>, got \"" + $volid + "\"");
    }
    def storage as string init strings.substring($volid, 0, $colon);
    def path as string init "/nodes/" + uri.encode($node) + "/storage/" + uri.encode($storage) +
        "/content/" + uri.encode($volid);
    return field(delete($c, $path, {}), "");
}

/**
 * Have a node download an ISO image or a container template from a URL
 * straight to a storage.
 *
 * @param c {Client} the client
 * @param node {string} the node
 * @param storage {string} a storage with that content type
 * @param content {string} `iso` or `vztmpl`
 * @param url {string} where to fetch it
 * @param filename {string} the file name on the storage
 * @return {string} the task's UPID
 * @throws {Error} kind `"proxmox"` on another content type, or as `call`
 */
export func downloadUrl(
    c as Client,
    node as string,
    storage as string,
    content as string,
    url as string,
    filename as string) {
    if ($content != "iso" and $content != "vztmpl") {
        fail("downloadUrl fetches iso or vztmpl, got \"" + $content + "\"");
    }
    def path as string init "/nodes/" + uri.encode($node) + "/storage/" + uri.encode($storage) +
        "/download-url";
    def params as map of string to string init {
        "content": $content,
        "url": $url,
        "filename": $filename
    };
    return upidOf(post($c, $path, $params), "downloadUrl");
}

/**
 * The container templates Proxmox offers for download, as `pveam available`
 * lists them.
 *
 * @param c {Client} the client
 * @param node {string} the node
 * @return {list of Appliance} the templates
 * @throws {Error} kind `"proxmox"` as `call`
 */
export func appliances(c as Client, node as string) {
    def d as json.Value init get($c, "/nodes/" + uri.encode($node) + "/aplinfo", {});
    def out as list of Appliance init [];
    for (def p in items($d)) {
        $out[] = Appliance{
            template: field($d, $p + "/template"),
            section: field($d, $p + "/section"),
            os: field($d, $p + "/os"),
            version: field($d, $p + "/version"),
            headline: field($d, $p + "/headline")
        };
    }
    return $out;
}

/**
 * Download a container template to a storage, as `pveam download` does.
 * Afterwards it is `<storage>:vztmpl/<template>`, ready for `createContainer`.
 *
 * @param c {Client} the client
 * @param node {string} the node
 * @param storage {string} a storage with `vztmpl` content
 * @param template {string} a `template` from `appliances`
 * @return {string} the task's UPID
 * @throws {Error} kind `"proxmox"` as `call`
 */
export func downloadAppliance(c as Client, node as string, storage as string, template as string) {
    def path as string init "/nodes/" + uri.encode($node) + "/aplinfo";
    return upidOf(
        post($c, $path, {"storage": $storage, "template": $template}),
        "downloadAppliance");
}

/**
 * The configuration keys of a cloud-init setting. Proxmox wants the SSH keys
 * percent-encoded once more inside the form, without a trailing newline.
 *
 * @param ci {CloudInit} the settings
 * @return {map of string to string} the keys for `setConfig`
 */
func cloudInitParams(ci as CloudInit) {
    def params as map of string to string init {};
    if ($ci.user != "") {
        $params["ciuser"] = $ci.user;
    }
    if ($ci.password != "") {
        $params["cipassword"] = $ci.password;
    }
    if (len($ci.sshKeys) > 0) {
        def keys as list of string init [];
        for (def k in $ci.sshKeys) {
            def t as string init strings.trim($k);
            if ($t != "") {
                $keys[] = $t;
            }
        }
        $params["sshkeys"] = uri.encode(strings.join($keys, "\n"));
    }
    def i as int init 0;
    while ($i < len($ci.ipConfig)) {
        $params["ipconfig" + convert.toString($i)] = $ci.ipConfig[$i];
        $i = $i + 1;
    }
    if ($ci.nameserver != "") {
        $params["nameserver"] = $ci.nameserver;
    }
    if ($ci.searchDomain != "") {
        $params["searchdomain"] = $ci.searchDomain;
    }
    return $params;
}

/**
 * Set a VM's cloud-init settings. The VM needs a cloud-init drive (e.g.
 * `ide2: local-lvm:cloudinit` through `setConfig`); the guest picks the
 * settings up at its next boot.
 *
 * @param c {Client} the client
 * @param g {Guest} a VM
 * @param ci {CloudInit} the settings; empty fields are left as they are
 * @return {null} nothing
 * @throws {Error} kind `"proxmox"` for a container, or as `call`
 */
export func setCloudInit(c as Client, g as Guest, ci as CloudInit) {
    if ($g.kind != "qemu") {
        fail("cloud-init is for VMs; a container takes its settings in createContainer");
    }
    return setConfig($c, $g, cloudInitParams($ci));
}

/**
 * The cluster's recent tasks, running ones included, newest first as
 * Proxmox sends them.
 *
 * @param c {Client} the client
 * @return {list of Task} the tasks; `exitStatus` is set once a task has stopped
 * @throws {Error} kind `"proxmox"` as `call`
 */
export func recentTasks(c as Client) {
    def d as json.Value init get($c, "/cluster/tasks", {});
    def out as list of Task init [];
    for (def p in items($d)) {
        def t as Task init Task{
            upid: field($d, $p + "/upid"),
            node: field($d, $p + "/node"),
            type: field($d, $p + "/type"),
            id: field($d, $p + "/id"),
            user: field($d, $p + "/user"),
            status: "running",
            exitStatus: ""
        };
        if (number($d, $p + "/endtime") > 0) {
            $t.status = "stopped";
            $t.exitStatus = field($d, $p + "/status");
        }
        $out[] = $t;
    }
    return $out;
}

/**
 * A node's status: CPU model and load, memory, swap, root disk, kernel,
 * Proxmox version, uptime.
 *
 * @param c {Client} the client
 * @param node {string} the node
 * @return {json.Value} the status, Proxmox's keys as they are
 * @throws {Error} kind `"proxmox"` as `call`
 */
export func nodeStatus(c as Client, node as string) {
    return get($c, "/nodes/" + uri.encode($node) + "/status", {});
}

/**
 * Check a metrics time frame.
 *
 * @param timeframe {string} the time frame
 * @return {map of string to string} the query parameters
 */
func metricsParams(timeframe as string) {
    if (not lists.contains(["hour", "day", "week", "month", "year"], $timeframe)) {
        fail("a time frame is hour, day, week, month or year, got \"" + $timeframe + "\"");
    }
    return {"timeframe": $timeframe, "cf": "AVERAGE"};
}

/**
 * A node's load over time: one sample per step (a minute for `hour`), with
 * `time`, `cpu`, `memused`, `netin`, `netout`, `loadavg` and more.
 *
 * @param c {Client} the client
 * @param node {string} the node
 * @param timeframe {string} `hour`, `day`, `week`, `month` or `year`
 * @return {json.Value} the list of samples, averaged
 * @throws {Error} kind `"proxmox"` on another time frame, or as `call`
 */
export func nodeMetrics(c as Client, node as string, timeframe as string) {
    return get($c, "/nodes/" + uri.encode($node) + "/rrddata", metricsParams($timeframe));
}

/**
 * A guest's load over time, with `time`, `cpu`, `mem`, `netin`, `netout`,
 * `diskread`, `diskwrite` per sample.
 *
 * @param c {Client} the client
 * @param g {Guest} the guest
 * @param timeframe {string} `hour`, `day`, `week`, `month` or `year`
 * @return {json.Value} the list of samples, averaged
 * @throws {Error} kind `"proxmox"` on another time frame, or as `call`
 */
export func guestMetrics(c as Client, g as Guest, timeframe as string) {
    return get($c, guestPath($g) + "/rrddata", metricsParams($timeframe));
}

/**
 * The resource pools.
 *
 * @param c {Client} the client
 * @return {list of Pool} the pools
 * @throws {Error} kind `"proxmox"` as `call`
 */
export func pools(c as Client) {
    def d as json.Value init get($c, "/pools", {});
    def out as list of Pool init [];
    for (def p in items($d)) {
        $out[] = Pool{poolid: field($d, $p + "/poolid"), comment: field($d, $p + "/comment")};
    }
    return $out;
}

/**
 * Create a resource pool.
 *
 * @param c {Client} the client
 * @param poolid {string} the pool id
 * @param comment {string} a comment; "" for none
 * @return {null} nothing
 * @throws {Error} kind `"proxmox"` as `call`
 */
export func createPool(c as Client, poolid as string, comment as string) {
    def params as map of string to string init {"poolid": $poolid};
    if ($comment != "") {
        $params["comment"] = $comment;
    }
    post($c, "/pools", $params);
    return null;
}

/**
 * Add guests to a pool.
 *
 * @param c {Client} the client
 * @param poolid {string} the pool
 * @param vmids {list of int} the guests
 * @return {null} nothing
 * @throws {Error} kind `"proxmox"` as `call`
 */
export func addToPool(c as Client, poolid as string, vmids as list of int) {
    def ids as list of string init [];
    for (def id in $vmids) {
        $ids[] = convert.toString($id);
    }
    put($c, "/pools/" + uri.encode($poolid), {"vms": strings.join($ids, ",")});
    return null;
}

/**
 * Delete an empty pool.
 *
 * @param c {Client} the client
 * @param poolid {string} the pool
 * @return {null} nothing
 * @throws {Error} kind `"proxmox"` as `call`; Proxmox refuses a pool with members
 */
export func deletePool(c as Client, poolid as string) {
    delete($c, "/pools/" + uri.encode($poolid), {});
    return null;
}

/**
 * The HA id of a guest.
 *
 * @param g {Guest} the guest
 * @return {string} `vm:<vmid>` or `ct:<vmid>`
 */
func haSid(g as Guest) {
    if ($g.kind == "lxc") {
        return "ct:" + convert.toString($g.vmid);
    }
    return "vm:" + convert.toString($g.vmid);
}

/**
 * The guests under high availability.
 *
 * @param c {Client} the client
 * @return {list of HaResource} the HA resources
 * @throws {Error} kind `"proxmox"` as `call`
 */
export func haResources(c as Client) {
    def d as json.Value init get($c, "/cluster/ha/resources", {});
    def out as list of HaResource init [];
    for (def p in items($d)) {
        $out[] = HaResource{
            sid: field($d, $p + "/sid"),
            state: field($d, $p + "/state"),
            group: field($d, $p + "/group")
        };
    }
    return $out;
}

/**
 * Put a guest under high availability: the cluster restarts it on another
 * node when its node fails.
 *
 * @param c {Client} the client
 * @param g {Guest} the guest
 * @param state {string} `started`, `stopped`, `disabled` or `ignored`
 * @return {null} nothing
 * @throws {Error} kind `"proxmox"` as `call`
 */
export func enableHa(c as Client, g as Guest, state as string) {
    post($c, "/cluster/ha/resources", {"sid": haSid($g), "state": $state});
    return null;
}

/**
 * Take a guest out of high availability. The guest keeps running.
 *
 * @param c {Client} the client
 * @param g {Guest} the guest
 * @return {null} nothing
 * @throws {Error} kind `"proxmox"` as `call`
 */
export func disableHa(c as Client, g as Guest) {
    delete($c, "/cluster/ha/resources/" + uri.encode(haSid($g)), {});
    return null;
}

/**
 * A guest's firewall rules, in order. They apply only while the firewall is
 * on for the guest (`firewall` options) and for its NIC (`firewall=1`).
 *
 * @param c {Client} the client
 * @param g {Guest} the guest
 * @return {list of FirewallRule} the rules
 * @throws {Error} kind `"proxmox"` as `call`
 */
export func firewallRules(c as Client, g as Guest) {
    def d as json.Value init get($c, guestPath($g) + "/firewall/rules", {});
    def out as list of FirewallRule init [];
    for (def p in items($d)) {
        $out[] = FirewallRule{
            pos: number($d, $p + "/pos"),
            type: field($d, $p + "/type"),
            action: field($d, $p + "/action"),
            enable: flag($d, $p + "/enable"),
            source: field($d, $p + "/source"),
            dest: field($d, $p + "/dest"),
            proto: field($d, $p + "/proto"),
            dport: field($d, $p + "/dport"),
            macro: field($d, $p + "/macro"),
            comment: field($d, $p + "/comment")
        };
    }
    return $out;
}

/**
 * Add a firewall rule at the top of a guest's rules, enabled. Fields left
 * empty are not sent.
 *
 * @param c {Client} the client
 * @param g {Guest} the guest
 * @param rule {FirewallRule} the rule; `pos` and `enable` are ignored
 * @return {null} nothing
 * @throws {Error} kind `"proxmox"` as `call`
 */
export func addFirewallRule(c as Client, g as Guest, rule as FirewallRule) {
    def params as map of string to string init {
        "type": $rule.type,
        "action": $rule.action,
        "enable": "1"
    };
    def optional as map of string to string init {
        "source": $rule.source,
        "dest": $rule.dest,
        "proto": $rule.proto,
        "dport": $rule.dport,
        "macro": $rule.macro,
        "comment": $rule.comment
    };
    for (def key in $optional) {
        if ($optional[$key] != "") {
            $params[$key] = $optional[$key];
        }
    }
    post($c, guestPath($g) + "/firewall/rules", $params);
    return null;
}

/**
 * Delete a firewall rule by position.
 *
 * @param c {Client} the client
 * @param g {Guest} the guest
 * @param pos {int} the rule's position, from `firewallRules`
 * @return {null} nothing
 * @throws {Error} kind `"proxmox"` as `call`
 */
export func deleteFirewallRule(c as Client, g as Guest, pos as int) {
    delete($c, guestPath($g) + "/firewall/rules/" + convert.toString($pos), {});
    return null;
}

/**
 * The user accounts.
 *
 * @param c {Client} the client
 * @return {list of User} the users
 * @throws {Error} kind `"proxmox"` as `call`
 */
export func users(c as Client) {
    def d as json.Value init get($c, "/access/users", {});
    def out as list of User init [];
    for (def p in items($d)) {
        $out[] = User{
            userid: field($d, $p + "/userid"),
            enabled: kindAt($d, $p + "/enable") == "missing" or flag($d, $p + "/enable"),
            expire: number($d, $p + "/expire"),
            firstname: field($d, $p + "/firstname"),
            lastname: field($d, $p + "/lastname"),
            email: field($d, $p + "/email"),
            comment: field($d, $p + "/comment")
        };
    }
    return $out;
}

/**
 * The permissions.
 *
 * @param c {Client} the client
 * @return {list of Acl} the access control list
 * @throws {Error} kind `"proxmox"` as `call`
 */
export func permissions(c as Client) {
    def d as json.Value init get($c, "/access/acl", {});
    def out as list of Acl init [];
    for (def p in items($d)) {
        $out[] = Acl{
            path: field($d, $p + "/path"),
            type: field($d, $p + "/type"),
            ugid: field($d, $p + "/ugid"),
            roleid: field($d, $p + "/roleid"),
            propagate: flag($d, $p + "/propagate")
        };
    }
    return $out;
}

/**
 * The form of a permission change.
 *
 * @param acl {Acl} the permission
 * @return {map of string to string} the parameters of `PUT /access/acl`
 */
func aclParams(acl as Acl) {
    def key as string init "";
    if ($acl.type == "user") {
        $key = "users";
    } elseif ($acl.type == "group") {
        $key = "groups";
    } elseif ($acl.type == "token") {
        $key = "tokens";
    } else {
        fail("a permission is for a user, group or token, got \"" + $acl.type + "\"");
    }
    def propagate as string init "0";
    if ($acl.propagate) {
        $propagate = "1";
    }
    return {"path": $acl.path, "roles": $acl.roleid, $key: $acl.ugid, "propagate": $propagate};
}

/**
 * Grant a role on a path.
 *
 * @param c {Client} the client
 * @param acl {Acl} the permission, e.g. `PVEVMUser` on `/vms/101` for user
 *   `ada@pve`
 * @return {null} nothing
 * @throws {Error} kind `"proxmox"` on another `type`, or as `call`
 */
export func grant(c as Client, acl as Acl) {
    put($c, "/access/acl", aclParams($acl));
    return null;
}

/**
 * Take a permission away.
 *
 * @param c {Client} the client
 * @param acl {Acl} the permission, as `permissions` lists it
 * @return {null} nothing
 * @throws {Error} kind `"proxmox"` on another `type`, or as `call`
 */
export func revoke(c as Client, acl as Acl) {
    def params as map of string to string init aclParams($acl);
    $params["delete"] = "1";
    put($c, "/access/acl", $params);
    return null;
}

/**
 * The pause between two status checks. A client built without `client` has
 * `pollMs` 0, which would ask without pause; it waits a second instead.
 *
 * @param c {Client} the client
 * @return {int} milliseconds, at least 1
 */
func pollDelay(c as Client) {
    if ($c.pollMs <= 0) {
        return 1000;
    }
    return $c.pollMs;
}

/**
 * Whether an address is loopback or link-local, so useless from outside the
 * guest.
 *
 * @param ip {string} an IPv4 or IPv6 address, without prefix
 * @return {bool} true for 127.0.0.0/8, 169.254.0.0/16, ::1 and fe80::/10
 */
func isLocalAddress(ip as string) {
    def low as string init strings.lower($ip);
    for (def prefix in ["127.", "169.254.", "fe8", "fe9", "fea", "feb"]) {
        if (strings.startsWith($low, $prefix)) {
            return true;
        }
    }
    return $low == "::1";
}

/**
 * Count a failed status check, or give up. A 4xx answer is final (a bad
 * credential does not heal by waiting); a network failure or a 5xx answer
 * is retried up to `MAX_POLL_FAILURES` times in a row.
 *
 * @param e {Error} the failure
 * @param failures {int} failures in a row so far
 * @return {int} the new count
 * @throws {Error} the failure itself, when it is final
 */
func retryOrThrow(e as Error, failures as int) {
    if ($e.kind != ERROR_KIND or regex.matches(": HTTP 4[0-9][0-9]", $e.message)) {
        throw $e;
    }
    if ($failures + 1 >= MAX_POLL_FAILURES) {
        throw $e;
    }
    return $failures + 1;
}

/**
 * When a ticket was issued: `PVE:<user>:<hex time>::<signature>`.
 *
 * @param ticket {string} the ticket
 * @return {int} Unix time; -1 when the ticket has another shape
 */
func ticketIssued(ticket as string) {
    def parts as list of string init strings.split($ticket, ":");
    if (len($parts) < 3) {
        return -1;
    }
    try {
        return convert.toInt($parts[2], 16);
    } catch (e) {
        return -1;
    }
}

/**
 * Keep a ticket valid: renew it once it is older than an hour. Call it
 * before each batch of work in a long-running program; a token client, or a
 * young ticket, comes back unchanged without a request.
 *
 * @param c {Client} the client
 * @return {Client} the client with a ticket valid for at least an hour
 * @throws {Error} kind `"proxmox"` when the ticket has run out (log in again),
 *   or as `renew`
 */
export func fresh(c as Client) {
    if ($c.ticket == "") {
        return $c;
    }
    def issued as int init ticketIssued($c.ticket);
    if ($issued < 0) {
        return renew($c);
    }
    def age as int init time.unix(time.now()) - $issued;
    if ($age >= TICKET_LIFETIME) {
        fail("the ticket ran out " + convert.toString($age - TICKET_LIFETIME) +
            " s ago: log in again");
    }
    if ($age < TICKET_LIFETIME // 2) {
        return $c;
    }
    return renew($c);
}

/**
 * A one-line description of a client for logs, without its secret, token
 * secret or ticket. Print this, never the `Client` itself: its fields hold
 * the credential in plain text.
 *
 * @param c {Client} the client
 * @return {string} e.g. `https://pve:8006 (API token root@pam!ci)`
 */
export func describe(c as Client) {
    def who as string init "no credential";
    if ($c.tokenId != "") {
        $who = "API token " + $c.tokenId;
    } elseif ($c.ticket != "") {
        $who = "ticket for " + ticketUser($c.ticket);
    }
    if ($c.tls.skipVerify) {
        $who = $who + ", certificate not checked";
    }
    return $c.url + " (" + $who + ")";
}
