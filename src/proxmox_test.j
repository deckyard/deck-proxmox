# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev>
# pragma-jennifer-version: >=0.25.0

/**
 * White-box tests for proxmox: jennifer test src/proxmox_test.j
 *
 * The parsing and checking helpers are tested directly. The requests go to an
 * `httpd` server on a loopback port that answers with canned Proxmox replies
 * and hands back what it received.
 */
use httpd;
use task;
use testing;

/** A canned reply. */
def struct Reply {
    status as int,
    body as string
};

/** One request as the fake server saw it. */
def struct Seen {
    method as string,
    path as string,
    query as string,
    auth as string,
    cookie as string,
    csrf as string,
    contentType as string,
    body as string
};

/** A running fake server. */
def struct Fake {
    srv as httpd.Server,
    url as string,
    t as task of list of Seen
};

def const UPID as string init "UPID:pve1:0001A2B3:0042C0DE:66F0A1B2:qmstart:101:root@pam:";

/**
 * The query parameters the tests send, as `key=value&...` in a fixed order.
 * Not `httpd.rawQuery`: 0.25.0 does not have it.
 *
 * @param req {httpd.Request} the request
 * @return {string} the parameters that are set
 */
func queryOf(req as httpd.Request) {
    def parts as list of string init [];
    for (def key in ["type", "source", "vmid", "force", "limit", "purge", "content", "timeframe"]) {
        def value as string init httpd.query($req, $key);
        if ($value != "") {
            $parts[] = $key + "=" + $value;
        }
    }
    return strings.join($parts, "&");
}

/**
 * Answer one request per reply, in order.
 *
 * @param srv {httpd.Server} the listening server
 * @param replies {list of Reply} the replies
 * @return {list of Seen} the requests
 */
func serve(srv as httpd.Server, replies as list of Reply) {
    def seen as list of Seen init [];
    for (def r in $replies) {
        def req as httpd.Request init httpd.accept($srv);
        $seen[] = Seen{
            method: httpd.method($req),
            path: httpd.path($req),
            query: queryOf($req),
            auth: httpd.header($req, "Authorization"),
            cookie: httpd.header($req, "Cookie"),
            csrf: httpd.header($req, "CSRFPreventionToken"),
            contentType: httpd.header($req, "Content-Type"),
            body: convert.stringFromBytes(httpd.body($req), "utf-8")
        };
        httpd.respond($req, $r.status, $r.body);
    }
    return $seen;
}

/**
 * Start a fake server that gives these replies.
 *
 * @param replies {list of Reply} the replies
 * @return {Fake} the server
 */
func fake(replies as list of Reply) {
    def srv as httpd.Server init httpd.listen("127.0.0.1:0");
    def t as task of list of Seen init spawn {
        return serve($srv, $replies);
    };
    return Fake{srv: $srv, url: "http://" + httpd.address($srv), t: $t};
}

/**
 * Stop a fake server.
 *
 * @param f {Fake} the server
 * @return {list of Seen} what it received
 */
func finish(f as Fake) {
    def seen as list of Seen init task.wait($f.t);
    httpd.shutdown($f.srv);
    return $seen;
}

/**
 * A 200 reply wrapping `data`.
 *
 * @param data {string} the JSON of `data`
 * @return {Reply} the reply
 */
func ok(data as string) {
    return Reply{status: 200, body: '{"data":' + $data + '}'};
}

/**
 * A token client for a fake server.
 *
 * @param f {Fake} the server
 * @return {Client} the client
 */
func tokenClient(f as Fake) {
    return withToken(client($f.url), "root@pam!ci", "0b1c-secret");
}

/**
 * A guest on node pve1.
 *
 * @param kind {string} `qemu` or `lxc`
 * @return {Guest} the guest
 */
func sample(kind as string) {
    def g as Guest;
    $g.vmid = 101;
    $g.node = "pve1";
    $g.kind = $kind;
    return $g;
}

/**
 * Mark a call that should have thrown. The error reaches the test's own
 * `catch`, whose assertions on kind and message then fail.
 *
 * @param what {string} what got through
 * @throws {Error} always, with `kind` `"missed"`
 */
func missed(what as string) {
    throw Error{kind: "missed", message: $what};
}

func emptyHost() {
    client("  ");
}

func badTokenId() {
    withToken(client("pve"), "root@pam", "s");
}

func pathWithoutSlash() {
    ensurePath("nodes");
}

func pathUp() {
    ensurePath("/nodes/../access");
}

func pathWithQuery() {
    ensurePath("/nodes?x=1");
}

func patchMethod() {
    call(client("pve"), "PATCH", "/nodes", {});
}

func notAUpid() {
    parseUpid("UPID:short");
}

func wrongKind() {
    guestPath(sample("docker"));
}

func renewWithoutTicket() {
    renew(withToken(client("pve"), "root@pam!ci", "s"));
}

func unreachable() {
    get(withTimeout(client("http://127.0.0.1:1"), 2000), "/version", {});
}

func testBaseUrl() {
    testing.assertEqual(baseUrl("pve.example.com"), "https://pve.example.com:8006");
    testing.assertEqual(baseUrl("10.0.0.5:443"), "https://10.0.0.5:443");
    testing.assertEqual(baseUrl("https://pve:8006/"), "https://pve:8006");
    testing.assertEqual(baseUrl("https://pve:8006/api2/json/"), "https://pve:8006");
    testing.assertEqual(baseUrl("[fd00::5]"), "https://[fd00::5]:8006");
    testing.assertEqual(baseUrl("[fd00::5]:8007"), "https://[fd00::5]:8007");
    testing.assertEqual(baseUrl("http://127.0.0.1:9"), "http://127.0.0.1:9");
    testing.assertThrows("emptyHost", ERROR_KIND);
}

func testBuilders() {
    def c as Client init client("pve");
    testing.assertEqual($c.pollMs, 1000);
    testing.assertEqual($c.tls.skipVerify, false);
    testing.assertEqual(withInsecure($c).tls.skipVerify, true);
    def pem as bytes init convert.bytesFromString("-----BEGIN CERTIFICATE-----", "utf-8");
    def trusted as Client init withCaCert(withInsecure($c), $pem);
    testing.assertEqual($trusted.tls.skipVerify, false);
    testing.assertEqual($trusted.tls.caCert, $pem);
    testing.assertEqual(withTimeout($c, 5000).timeoutMs, 5000);
    testing.assertEqual(withRetries($c, 3).retries, 3);
    testing.assertEqual(withPollInterval($c, 50).pollMs, 50);
    testing.assertThrows("badTokenId", ERROR_KIND);
}

func testTokenAndTicketReplaceEachOther() {
    def c as Client init withTicket(client("pve"), "PVE:root@pam:66F0::sig", "66F0:csrf");
    $c = withToken($c, "root@pam!ci", "s");
    testing.assertEqual($c.ticket, "");
    testing.assertEqual($c.csrf, "");
    $c = withTicket($c, "PVE:root@pam:66F0::sig", "66F0:csrf");
    testing.assertEqual($c.tokenId, "");
    testing.assertEqual($c.secret, "");
}

func testAuthHeaders() {
    def token as Client init withToken(client("pve"), "root@pam!ci", "uuid");
    def sent as map of string to string init authHeaders($token, "POST");
    testing.assertEqual($sent["Authorization"], "PVEAPIToken=root@pam!ci=uuid");
    testing.assertEqual(maps.has(authHeaders($token, "POST"), "CSRFPreventionToken"), false);
    def ticket as Client init withTicket(client("pve"), "PVE:root@pam:66F0::a+b/c=", "66F0:x");
    def cookie as string init "PVEAuthCookie=PVE:root@pam:66F0::a+b/c=";
    testing.assertEqual(authHeaders($ticket, "GET")["Cookie"], $cookie);
    testing.assertEqual(maps.has(authHeaders($ticket, "GET"), "CSRFPreventionToken"), false);
    testing.assertEqual(authHeaders($ticket, "DELETE")["CSRFPreventionToken"], "66F0:x");
    testing.assertEqual(maps.has(authHeaders(client("pve"), "GET"), "Authorization"), false);
}

func testPathsAreChecked() {
    ensurePath("/nodes/pve1/qemu");
    testing.assertThrows("pathWithoutSlash", ERROR_KIND);
    testing.assertThrows("pathUp", ERROR_KIND);
    testing.assertThrows("pathWithQuery", ERROR_KIND);
    testing.assertThrows("patchMethod", ERROR_KIND);
}

func testFailureText() {
    def r as http.Response;
    $r.status = 500;
    $r.statusText = "VM 101 not running";
    $r.body = '{"data":null}';
    testing.assertEqual(failureText($r), "HTTP 500: VM 101 not running");
    $r.body = '{"data":null,"message":"VM 101 is locked (backup)\n"}';
    testing.assertEqual(failureText($r), "HTTP 500: VM 101 is locked (backup)");
    $r.status = 400;
    $r.statusText = "Parameter verification failed.";
    $r.body = '{"data":null,"errors":{"vmid":"invalid format\n","a/b":"bad"}}';
    testing.assertEqual(
        failureText($r),
        "HTTP 400: Parameter verification failed. (vmid: invalid format; a/b: bad)");
    $r.status = 401;
    $r.statusText = "";
    $r.body = "";
    testing.assertEqual(failureText($r), "HTTP 401");
}

func testReadersTolerateProxmoxTypes() {
    def d as json.Value init json.decode('{"s":"7","i":3,"f":0.25,"t":true,"n":null,"x":"abc"}');
    testing.assertEqual(field($d, "/s"), "7");
    testing.assertEqual(field($d, "/i"), "3");
    testing.assertEqual(field($d, "/n"), "");
    testing.assertEqual(field($d, "/missing"), "");
    testing.assertEqual(number($d, "/s"), 7);
    testing.assertEqual(number($d, "/f"), 0);
    testing.assertEqual(number($d, "/t"), 1);
    testing.assertEqual(number($d, "/x"), 0);
    testing.assertEqual(real($d, "/f"), 0.25);
    testing.assertEqual(real($d, "/s"), 7.0);
    testing.assertEqual(real($d, "/x"), 0.0);
    testing.assertEqual(flag($d, "/i"), false);
    testing.assertEqual(flag($d, "/t"), true);
    testing.assertEqual(flag(json.decode('{"a":1}'), "/a"), true);
    testing.assertEqual(splitList(" images, ,rootdir ", ","), ["images", "rootdir"]);
    testing.assertEqual(items(json.decode('{"a":1}')), []);
    testing.assertEqual(pointerToken("a~/b"), "a~0~1b");
}

func testParseUpid() {
    def t as Task init parseUpid(UPID);
    testing.assertEqual($t.node, "pve1");
    testing.assertEqual($t.type, "qmstart");
    testing.assertEqual($t.id, "101");
    testing.assertEqual($t.user, "root@pam");
    testing.assertEqual($t.status, "");
    testing.assertThrows("notAUpid", ERROR_KIND);
    testing.assertEqual(ticketUser("PVE:root@pam:66F0A1B2::sig"), "root@pam");
    testing.assertEqual(ticketUser("junk"), "");
}

func testGuestPath() {
    testing.assertEqual(guestPath(sample("qemu")), "/nodes/pve1/qemu/101");
    testing.assertEqual(guestPath(sample("lxc")), "/nodes/pve1/lxc/101");
    testing.assertThrows("wrongKind", ERROR_KIND);
}

func testLoginKeepsTheTicket() {
    def f as Fake init fake([
        ok('{"ticket":"PVE:root@pam:66F0::s+g=","CSRFPreventionToken":"66F0:tok"}'),
        ok('{"version":"8.2.4","release":"8.2","repoid":"faa83925"}'),
        ok("null")
    ]);
    def c as Client init login(client($f.url), "root@pam", "p&ss word");
    testing.assertEqual($c.ticket, "PVE:root@pam:66F0::s+g=");
    testing.assertEqual($c.csrf, "66F0:tok");
    def v as Version init version($c);
    put($c, "/nodes/pve1/config", {"description": "lab"});
    def seen as list of Seen init finish($f);
    testing.assertEqual($v, Version{version: "8.2.4", release: "8.2", repoid: "faa83925"});
    testing.assertEqual($seen[0].method, "POST");
    testing.assertEqual($seen[0].path, "/api2/json/access/ticket");
    testing.assertEqual($seen[0].contentType, "application/x-www-form-urlencoded");
    testing.assertEqual($seen[0].body, "username=root%40pam&password=p%26ss+word");
    testing.assertEqual($seen[0].cookie, "");
    testing.assertEqual($seen[1].cookie, "PVEAuthCookie=PVE:root@pam:66F0::s+g=");
    testing.assertEqual($seen[1].csrf, "");
    testing.assertEqual($seen[2].method, "PUT");
    testing.assertEqual($seen[2].csrf, "66F0:tok");
    testing.assertEqual($seen[2].body, "description=lab");
}

func testLoginRefusesASecondFactor() {
    def f as Fake init fake([ok('{"NeedTFA":1,"ticket":"PVE:!tfa!challenge"}')]);
    try {
        login(client($f.url), "ada@pve", "pw");
        missed("login passed a second factor by");
    } catch (e) {
        testing.assertTrue(strings.contains($e.message, "loginTotp"));
    }
    finish($f);
}

func testLoginTotpAnswersTheChallenge() {
    def f as Fake init fake([
        ok('{"NeedTFA":1,"ticket":"PVE:!tfa!challenge","username":"ada@pve"}'),
        ok('{"ticket":"PVE:ada@pve:66F0::sig","CSRFPreventionToken":"66F0:c"}')
    ]);
    def c as Client init loginTotp(client($f.url), "ada@pve", "pw", "123456");
    def seen as list of Seen init finish($f);
    testing.assertEqual($c.ticket, "PVE:ada@pve:66F0::sig");
    testing.assertEqual(uri.parseQuery($seen[1].body)["tfa-challenge"], "PVE:!tfa!challenge");
    testing.assertEqual(uri.parseQuery($seen[1].body)["password"], "totp:123456");
}

func testLoginTotpWithoutAChallenge() {
    def f as Fake init fake([ok('{"ticket":"PVE:ada@pve:66F0::sig","CSRFPreventionToken":"c"}')]);
    def c as Client init loginTotp(client($f.url), "ada@pve", "pw", "123456");
    finish($f);
    testing.assertEqual($c.csrf, "c");
}

func testRenewSendsTheTicketAsPassword() {
    def f as Fake init fake([ok('{"ticket":"PVE:root@pam:66F1::new","CSRFPreventionToken":"c"}')]);
    def c as Client init withTicket(client($f.url), "PVE:root@pam:66F0::old", "66F0:c");
    $c = renew($c);
    def seen as list of Seen init finish($f);
    testing.assertEqual($c.ticket, "PVE:root@pam:66F1::new");
    testing.assertEqual($seen[0].cookie, "");
    testing.assertEqual(uri.parseQuery($seen[0].body)["password"], "PVE:root@pam:66F0::old");
    testing.assertEqual(uri.parseQuery($seen[0].body)["username"], "root@pam");
    testing.assertThrows("renewWithoutTicket", ERROR_KIND);
}

func testALoginWithoutTicketFails() {
    def f as Fake init fake([ok('{}')]);
    try {
        login(client($f.url), "root@pam", "pw");
        missed("an empty login reply passed");
    } catch (e) {
        testing.assertEqual($e.kind, ERROR_KIND);
        testing.assertTrue(strings.contains($e.message, "no ticket"));
    }
    finish($f);
}

func testRefusalsBecomeDeckErrors() {
    def f as Fake init fake([
        Reply{status: 500, body: '{"data":null,"message":"VM 101 down\n"}'},
        Reply{status: 200, body: "<html>"}
    ]);
    def c as Client init tokenClient($f);
    try {
        post($c, "/nodes/pve1/qemu/101/status/stop", {});
        missed("a 500 passed");
    } catch (e) {
        testing.assertEqual($e.kind, ERROR_KIND);
        def want as string init "POST /nodes/pve1/qemu/101/status/stop: HTTP 500: VM 101 down";
        testing.assertEqual($e.message, "proxmox: " + $want);
    }
    try {
        get($c, "/version", {});
        missed("HTML passed for JSON");
    } catch (e) {
        testing.assertTrue(strings.contains($e.message, "not JSON"));
    }
    finish($f);
    testing.assertThrows("unreachable", ERROR_KIND);
}

func testGetSendsTheQueryAndTheToken() {
    def f as Fake init fake([ok("[]"), Reply{status: 200, body: ""}, ok("null")]);
    def c as Client init withRetries(tokenClient($f), 2);
    get($c, "/cluster/tasks", {"source": "active", "vmid": "101"});
    testing.assertEqual(json.typeOf(delete($c, "/pools/lab", {"force": "1"})), "null");
    testing.assertEqual(json.typeOf(post($c, "/pools", {"poolid": "lab"})), "null");
    def seen as list of Seen init finish($f);
    testing.assertEqual($seen[0].query, "source=active&vmid=101");
    testing.assertEqual($seen[0].auth, "PVEAPIToken=root@pam!ci=0b1c-secret");
    testing.assertEqual($seen[0].body, "");
    testing.assertEqual($seen[1].method, "DELETE");
    testing.assertEqual($seen[1].query, "force=1");
    testing.assertEqual($seen[2].body, "poolid=lab");
}

func testNodes() {
    def f as Fake init fake([
        ok(
            '[{"node":"pve2","status":"offline"},' +
                '{"node":"pve1","status":"online","cpu":0.031,"maxcpu":16,' +
                '"mem":8589934592,"maxmem":68719476736,"uptime":86400}]')
    ]);
    def ns as list of Node init nodes(tokenClient($f));
    finish($f);
    testing.assertEqual(len($ns), 2);
    testing.assertEqual($ns[0].node, "pve1");
    testing.assertEqual($ns[0].cpu, 0.031);
    testing.assertEqual($ns[0].maxcpu, 16);
    testing.assertEqual($ns[0].maxmem, 68719476736);
    testing.assertEqual($ns[1].status, "offline");
    testing.assertEqual($ns[1].uptime, 0);
}

def const RESOURCES as string init '[{"id":"lxc/200","type":"lxc","vmid":200,"name":"dns",' +
    '"node":"pve2",' +
    '"status":"running","maxdisk":8589934592,"disk":1073741824,"tags":"infra;dns"},' +
    '{"id":"storage/pve1/local","type":"storage","storage":"local","node":"pve1"},' +
    '{"id":"qemu/101","type":"qemu","vmid":101,"name":"web","node":"pve1","status":"stopped",' +
    '"template":0,"maxcpu":4,"maxmem":4294967296,"cpu":0},' +
    '{"id":"qemu/9000","type":"qemu","vmid":9000,"name":"debian12","node":"pve1",' +
    '"status":"stopped","template":1}]';

func testGuests() {
    def f as Fake init fake([ok(RESOURCES), ok(RESOURCES), ok(RESOURCES)]);
    def c as Client init tokenClient($f);
    def gs as list of Guest init guests($c);
    def dns as Guest init guest($c, 200);
    try {
        guest($c, 404);
        missed("a missing guest was found");
    } catch (e) {
        testing.assertEqual($e.message, "proxmox: no guest 404");
    }
    def seen as list of Seen init finish($f);
    testing.assertEqual($seen[0].query, "type=vm");
    testing.assertEqual(len($gs), 3);
    testing.assertEqual($gs[0].vmid, 101);
    testing.assertEqual($gs[0].kind, "qemu");
    testing.assertEqual($gs[0].template, false);
    testing.assertEqual($gs[0].maxmem, 4294967296);
    testing.assertEqual($gs[0].tags, []);
    testing.assertEqual($gs[2].template, true);
    testing.assertEqual($dns.kind, "lxc");
    testing.assertEqual($dns.node, "pve2");
    testing.assertEqual($dns.disk, 1073741824);
    testing.assertEqual($dns.tags, ["infra", "dns"]);
}

func testStatusPrefersTheQmpStatus() {
    def f as Fake init fake([
        ok('{"status":"running","qmpstatus":"paused"}'),
        ok('{"status":"stopped"}')
    ]);
    def c as Client init tokenClient($f);
    testing.assertEqual(status($c, sample("qemu")), "paused");
    testing.assertEqual(status($c, sample("lxc")), "stopped");
    def seen as list of Seen init finish($f);
    testing.assertEqual($seen[0].path, "/api2/json/nodes/pve1/qemu/101/status/current");
    testing.assertEqual($seen[1].path, "/api2/json/nodes/pve1/lxc/101/status/current");
}

func testPowerActionsReturnTheUpid() {
    def replies as list of Reply init [];
    for (def i in lists.range(0, 7)) {
        $replies[] = ok('"' + UPID + '"');
    }
    def f as Fake init fake($replies);
    def c as Client init tokenClient($f);
    def vm as Guest init sample("qemu");
    testing.assertEqual(start($c, $vm), UPID);
    stop($c, $vm);
    shutdown($c, $vm, 0);
    shutdown($c, $vm, 120);
    reboot($c, $vm);
    suspend($c, sample("lxc"));
    resume($c, sample("lxc"));
    def seen as list of Seen init finish($f);
    def actions as list of string init [];
    for (def s in $seen) {
        testing.assertEqual($s.method, "POST");
        $actions[] = $s.path;
    }
    testing.assertEqual(
        $actions,
        [
            "/api2/json/nodes/pve1/qemu/101/status/start",
            "/api2/json/nodes/pve1/qemu/101/status/stop",
            "/api2/json/nodes/pve1/qemu/101/status/shutdown",
            "/api2/json/nodes/pve1/qemu/101/status/shutdown",
            "/api2/json/nodes/pve1/qemu/101/status/reboot",
            "/api2/json/nodes/pve1/lxc/101/status/suspend",
            "/api2/json/nodes/pve1/lxc/101/status/resume"
        ]);
    testing.assertEqual($seen[2].body, "");
    testing.assertEqual($seen[3].body, "timeout=120");
}

func testAnActionWithoutUpidFails() {
    def f as Fake init fake([ok("null")]);
    try {
        start(tokenClient($f), sample("qemu"));
        missed("a reply without a task id passed");
    } catch (e) {
        testing.assertEqual($e.message, "proxmox: start returned no task id");
    }
    finish($f);
}

func testConfig() {
    def cfg0 as string init '{"cores":4,"memory":"4096","net0":"virtio=BC:24:11:00:00:01"}';
    def f as Fake init fake([ok($cfg0), ok("null")]);
    def c as Client init tokenClient($f);
    def cfg as json.Value init config($c, sample("qemu"));
    setConfig($c, sample("qemu"), {"memory": "8192", "delete": "net1"});
    def seen as list of Seen init finish($f);
    testing.assertEqual(json.asInt($cfg, "/cores"), 4);
    testing.assertEqual($seen[0].path, "/api2/json/nodes/pve1/qemu/101/config");
    testing.assertEqual($seen[1].method, "PUT");
    testing.assertEqual($seen[1].body, "memory=8192&delete=net1");
}

func testNextIdAndClone() {
    def f as Fake init fake([ok('"105"'), ok('"' + UPID + '"'), ok('"' + UPID + '"')]);
    def c as Client init tokenClient($f);
    def id as int init nextId($c);
    clone($c, sample("qemu"), $id, "web2");
    clone($c, sample("lxc"), $id, "dns2");
    def seen as list of Seen init finish($f);
    testing.assertEqual($id, 105);
    testing.assertEqual($seen[0].path, "/api2/json/cluster/nextid");
    testing.assertEqual($seen[1].path, "/api2/json/nodes/pve1/qemu/101/clone");
    testing.assertEqual($seen[1].body, "newid=105&full=1&name=web2");
    testing.assertEqual($seen[2].body, "newid=105&full=1&hostname=dns2");
}

func testSnapshots() {
    def f as Fake init fake([
        ok('[{"name":"current","parent":"after","running":1},' +
            '{"name":"after","parent":"before","snaptime":1727000000,"description":"upgraded"},' +
            '{"name":"before","snaptime":1726000000,"vmstate":1}]'),
        ok('"' + UPID + '"'),
        ok('"' + UPID + '"'),
        ok('"' + UPID + '"')
    ]);
    def c as Client init tokenClient($f);
    def vm as Guest init sample("qemu");
    def ss as list of Snapshot init snapshots($c, $vm);
    snapshot($c, $vm, "pre-upgrade", "before 8.3");
    rollback($c, $vm, "before");
    deleteSnapshot($c, $vm, "after");
    def seen as list of Seen init finish($f);
    testing.assertEqual(len($ss), 3);
    testing.assertEqual($ss[0].name, "before");
    testing.assertEqual($ss[0].vmstate, true);
    testing.assertEqual($ss[0].parent, "");
    testing.assertEqual($ss[1].description, "upgraded");
    testing.assertEqual($ss[2].name, "current");
    testing.assertEqual($seen[1].body, "snapname=pre-upgrade&description=before+8.3");
    testing.assertEqual($seen[2].path, "/api2/json/nodes/pve1/qemu/101/snapshot/before/rollback");
    testing.assertEqual($seen[3].method, "DELETE");
    testing.assertEqual($seen[3].path, "/api2/json/nodes/pve1/qemu/101/snapshot/after");
}

func testStorages() {
    def f as Fake init fake([
        ok(
            '[{"storage":"local-lvm","type":"lvmthin","content":"rootdir,images","active":1,' +
                '"enabled":1,"shared":0,"total":100,"used":40,"avail":60},' +
                '{"storage":"backup","type":"nfs","content":"backup",' +
                '"active":0,"enabled":1,"shared":1}]')
    ]);
    def ss as list of Storage init storages(tokenClient($f), "pve 1");
    def seen as list of Seen init finish($f);
    testing.assertEqual($seen[0].path, "/api2/json/nodes/pve 1/storage");
    testing.assertEqual($ss[0].storage, "backup");
    testing.assertEqual($ss[0].shared, true);
    testing.assertEqual($ss[0].active, false);
    testing.assertEqual($ss[1].content, ["rootdir", "images"]);
    testing.assertEqual($ss[1].avail, 60);
}

func testTasks() {
    def f as Fake init fake([
        ok('{"status":"running","type":"qmstart"}'),
        ok('{"status":"running"}'),
        ok('{"status":"stopped","exitstatus":"OK"}'),
        ok('[{"n":1,"t":"starting VM 101"},{"n":2,"t":"TASK OK"}]')
    ]);
    def c as Client init withPollInterval(tokenClient($f), 1);
    def now as Task init taskStatus($c, UPID);
    def done as Task init waitTask($c, UPID, 0);
    def log as list of string init taskLog($c, UPID);
    def seen as list of Seen init finish($f);
    testing.assertEqual($now.status, "running");
    testing.assertEqual($now.node, "pve1");
    testing.assertEqual($done.exitStatus, "OK");
    testing.assertEqual($log, ["starting VM 101", "TASK OK"]);
    testing.assertEqual($seen[0].path, "/api2/json/nodes/pve1/tasks/" + UPID + "/status");
    testing.assertEqual($seen[3].query, "limit=500");
}

func testWaitTaskGivesUp() {
    def f as Fake init fake([ok('{"status":"running"}'), ok('{"status":"running"}')]);
    def c as Client init withPollInterval(tokenClient($f), 30);
    try {
        waitTask($c, UPID, 20);
        missed("waitTask did not give up");
    } catch (e) {
        testing.assertTrue(strings.contains($e.message, "still running after 20 ms"));
    }
    finish($f);
}

func createWithoutNode() {
    createVm(client("pve"), "", 120, {});
}

func createWithVmidParam() {
    createVm(client("pve"), "pve1", 120, {"vmid": "121"});
}

func containerWithoutTemplate() {
    createContainer(client("pve"), "pve1", 120, {"hostname": "dns"});
}

func linkedCloneOfAGuest() {
    linkedClone(client("pve"), sample("qemu"), 120, "web2");
}

func testCreate() {
    def f as Fake init fake([ok('"' + UPID + '"'), ok('"' + UPID + '"')]);
    def c as Client init tokenClient($f);
    def vm as map of string to string init {
        "name": "web3",
        "memory": "2048",
        "scsi0": "local-lvm:32",
        "net0": "virtio,bridge=vmbr0"
    };
    testing.assertEqual(createVm($c, "pve1", 120, $vm), UPID);
    def ct as map of string to string init {
        "ostemplate": "local:vztmpl/debian-12-standard_12.7-1_amd64.tar.zst",
        "hostname": "dns2",
        "rootfs": "local-lvm:8"
    };
    createContainer($c, "pve 2", 121, $ct);
    def seen as list of Seen init finish($f);
    testing.assertEqual($seen[0].method, "POST");
    testing.assertEqual($seen[0].path, "/api2/json/nodes/pve1/qemu");
    def form as map of string to string init uri.parseQuery($seen[0].body);
    testing.assertEqual($form["vmid"], "120");
    testing.assertEqual($form["scsi0"], "local-lvm:32");
    testing.assertEqual($form["net0"], "virtio,bridge=vmbr0");
    testing.assertEqual($seen[1].path, "/api2/json/nodes/pve 2/lxc");
    testing.assertEqual(uri.parseQuery($seen[1].body)["ostemplate"], $ct["ostemplate"]);
    testing.assertEqual(uri.parseQuery($seen[1].body)["vmid"], "121");
    testing.assertThrows("createWithoutNode", ERROR_KIND);
    testing.assertThrows("createWithVmidParam", ERROR_KIND);
    testing.assertThrows("containerWithoutTemplate", ERROR_KIND);
}

func testDestroy() {
    def f as Fake init fake([ok('"' + UPID + '"'), ok('"' + UPID + '"')]);
    def c as Client init tokenClient($f);
    destroy($c, sample("qemu"), false);
    destroy($c, sample("lxc"), true);
    def seen as list of Seen init finish($f);
    testing.assertEqual($seen[0].method, "DELETE");
    testing.assertEqual($seen[0].path, "/api2/json/nodes/pve1/qemu/101");
    testing.assertEqual($seen[0].query, "");
    testing.assertEqual($seen[1].path, "/api2/json/nodes/pve1/lxc/101");
    testing.assertEqual($seen[1].query, "purge=1");
}

func testTemplatesAndLinkedClones() {
    def f as Fake init fake([ok('"' + UPID + '"'), ok("null"), ok('"' + UPID + '"')]);
    def c as Client init tokenClient($f);
    testing.assertEqual(toTemplate($c, sample("qemu")), UPID);
    testing.assertEqual(toTemplate($c, sample("lxc")), "");
    def tpl as Guest init sample("qemu");
    $tpl.template = true;
    linkedClone($c, $tpl, 130, "web4");
    def seen as list of Seen init finish($f);
    testing.assertEqual($seen[0].path, "/api2/json/nodes/pve1/qemu/101/template");
    testing.assertEqual($seen[1].path, "/api2/json/nodes/pve1/lxc/101/template");
    testing.assertEqual($seen[2].body, "newid=130&full=0&name=web4");
    testing.assertThrows("linkedCloneOfAGuest", ERROR_KIND);
}

func badResize() {
    resizeDisk(client("pve"), sample("qemu"), "scsi0", "ten gigs");
}

func badBackupMode() {
    backup(client("pve"), sample("qemu"), "local", "live");
}

func restoreNotABackup() {
    restore(client("pve"), "pve1", 120, "local:iso/debian.iso", "");
}

func volumeWithoutStorage() {
    deleteVolume(client("pve"), "pve1", "backup.vma.zst");
}

func downloadADisk() {
    downloadUrl(client("pve"), "pve1", "local", "images", "https://x/a.qcow2", "a.qcow2");
}

func cloudInitOnAContainer() {
    def ci as CloudInit;
    setCloudInit(client("pve"), sample("lxc"), $ci);
}

func badTimeframe() {
    nodeMetrics(client("pve"), "pve1", "minute");
}

func grantToARole() {
    grant(
        client("pve"),
        Acl{path: "/", type: "role", ugid: "x", roleid: "PVEAdmin", propagate: true});
}

/**
 * A reply holding one UPID.
 *
 * @return {Reply} the reply
 */
func upidReply() {
    return ok('"' + UPID + '"');
}

func testGuestByName() {
    def f as Fake init fake([
        ok(RESOURCES),
        ok(RESOURCES),
        ok('[{"type":"qemu","vmid":1,"name":"a","node":"n"},' +
            '{"type":"qemu","vmid":2,"name":"a","node":"n"}]')
    ]);
    def c as Client init tokenClient($f);
    testing.assertEqual(guestByName($c, "dns").vmid, 200);
    try {
        guestByName($c, "ghost");
        missed("a missing guest was found");
    } catch (e) {
        testing.assertEqual($e.message, "proxmox: no guest named \"ghost\"");
    }
    try {
        guestByName($c, "a");
        missed("two guests passed as one");
    } catch (e) {
        testing.assertEqual($e.message, "proxmox: 2 guests are named \"a\"");
    }
    finish($f);
}

func testInterfacesAndAddresses() {
    def f as Fake init fake([
        ok('{"result":[{"name":"lo","hardware-address":"00:00:00:00:00:00","ip-addresses":' +
            '[{"ip-address":"127.0.0.1","ip-address-type":"ipv4","prefix":8}]},' +
            '{"name":"ens18","hardware-address":"bc:24:11:00:00:01","ip-addresses":' +
            '[{"ip-address":"10.0.0.5","ip-address-type":"ipv4","prefix":24},' +
            '{"ip-address":"fe80::be24:11ff:fe00:1","ip-address-type":"ipv6","prefix":64}]}]}'),
        ok('[{"name":"lo","hwaddr":"00:00:00:00:00:00","inet":"127.0.0.1/8","inet6":"::1/128"},' +
            '{"name":"eth0","hwaddr":"bc:24:11:00:00:02","inet":"10.0.0.6/24",' +
            '"inet6":"2001:db8::6/64"},' +
            '{"name":"eth1","hwaddr":"bc:24:11:00:00:03","inet":"169.254.3.4/16",' +
            '"inet6":"FE90::3/64"}]'),
        ok('{"result":[]}')
    ]);
    def c as Client init tokenClient($f);
    def vm as list of Interface init interfaces($c, sample("qemu"));
    def ct as list of string init ipAddresses($c, sample("lxc"));
    def none as list of string init ipAddresses($c, sample("qemu"));
    def seen as list of Seen init finish($f);
    testing.assertEqual(len($vm), 2);
    testing.assertEqual(
        $vm[1],
        Interface{
            name: "ens18",
            mac: "bc:24:11:00:00:01",
            addresses: ["10.0.0.5/24", "fe80::be24:11ff:fe00:1/64"]
        });
    testing.assertEqual($ct, ["10.0.0.6", "2001:db8::6"]);
    testing.assertEqual($none, []);
    testing.assertEqual(
        $seen[0].path,
        "/api2/json/nodes/pve1/qemu/101/agent/network-get-interfaces");
    testing.assertEqual($seen[1].path, "/api2/json/nodes/pve1/lxc/101/interfaces");
}

func testMigrateAndResize() {
    def f as Fake init fake([upidReply(), upidReply(), upidReply(), ok("null"), upidReply()]);
    def c as Client init tokenClient($f);
    migrate($c, sample("qemu"), "pve2", true);
    migrate($c, sample("lxc"), "pve2", true);
    migrate($c, sample("qemu"), "pve2", false);
    testing.assertEqual(resizeDisk($c, sample("qemu"), "scsi0", "+10G"), "");
    testing.assertEqual(resizeDisk($c, sample("lxc"), "rootfs", "16G"), UPID);
    def seen as list of Seen init finish($f);
    testing.assertEqual($seen[0].path, "/api2/json/nodes/pve1/qemu/101/migrate");
    testing.assertEqual($seen[0].body, "target=pve2&online=1");
    testing.assertEqual($seen[1].body, "target=pve2&restart=1");
    testing.assertEqual($seen[2].body, "target=pve2");
    testing.assertEqual($seen[3].method, "PUT");
    testing.assertEqual($seen[3].path, "/api2/json/nodes/pve1/qemu/101/resize");
    testing.assertEqual($seen[3].body, "disk=scsi0&size=%2B10G");
    testing.assertThrows("badResize", ERROR_KIND);
}

func testBackupAndRestore() {
    def f as Fake init fake([
        upidReply(),
        ok('[{"volid":"bak:backup/vzdump-qemu-101-2026_11_02.vma.zst","content":"backup",' +
            '"format":"vma.zst","size":2147483648,"ctime":1762045200,' +
            '"vmid":101,"notes":"nightly"},' +
            '{"volid":"bak:backup/vzdump-lxc-200-2026_11_01-01_00_00.tar.zst","content":"backup",' +
            '"format":"tar.zst","size":536870912,"ctime":1761958800,"vmid":200}]'),
        upidReply(),
        upidReply(),
        upidReply()
    ]);
    def c as Client init tokenClient($f);
    backup($c, sample("qemu"), "bak", "snapshot");
    def bs as list of Volume init backups($c, "pve1", "bak");
    restore($c, "pve1", 150, $bs[1].volid, "local-lvm");
    restore($c, "pve1", 250, $bs[0].volid, "");
    testing.assertEqual(deleteVolume($c, "pve1", $bs[0].volid), UPID);
    def seen as list of Seen init finish($f);
    testing.assertEqual($seen[0].path, "/api2/json/nodes/pve1/vzdump");
    testing.assertEqual($seen[0].body, "vmid=101&storage=bak&mode=snapshot&compress=zstd");
    testing.assertEqual($seen[1].path, "/api2/json/nodes/pve1/storage/bak/content");
    testing.assertEqual($seen[1].query, "content=backup");
    testing.assertEqual($bs[0].vmid, 200);
    testing.assertEqual($bs[1].notes, "nightly");
    testing.assertEqual($bs[1].size, 2147483648);
    testing.assertEqual($seen[2].path, "/api2/json/nodes/pve1/qemu");
    def qemu as map of string to string init uri.parseQuery($seen[2].body);
    testing.assertEqual($qemu["archive"], $bs[1].volid);
    testing.assertEqual($qemu["storage"], "local-lvm");
    testing.assertEqual($qemu["vmid"], "150");
    testing.assertEqual($seen[3].path, "/api2/json/nodes/pve1/lxc");
    def lxc as map of string to string init uri.parseQuery($seen[3].body);
    testing.assertEqual($lxc["ostemplate"], $bs[0].volid);
    testing.assertEqual($lxc["restore"], "1");
    testing.assertEqual(maps.has($lxc, "storage"), false);
    testing.assertEqual($seen[4].method, "DELETE");
    testing.assertEqual($seen[4].path, "/api2/json/nodes/pve1/storage/bak/content/" + $bs[0].volid);
    testing.assertThrows("badBackupMode", ERROR_KIND);
    testing.assertThrows("restoreNotABackup", ERROR_KIND);
    testing.assertThrows("volumeWithoutStorage", ERROR_KIND);
}

func testStorageContentsAndDownloads() {
    def f as Fake init fake([
        ok('[{"volid":"local:iso/debian.iso","content":"iso","format":"iso","size":658505728}]'),
        upidReply(),
        ok('[{"template":"debian-12-standard_12.7-1_amd64.tar.zst","section":"system",' +
            '"os":"debian-12","version":"12.7-1","headline":"Debian 12 Bookworm (standard)"}]'),
        upidReply()
    ]);
    def c as Client init tokenClient($f);
    def all as list of Volume init contents($c, "pve1", "local", "");
    downloadUrl(
        $c,
        "pve1",
        "local",
        "iso",
        "https://cdimage.debian.org/x/debian-12.iso",
        "debian-12.iso");
    def apps as list of Appliance init appliances($c, "pve1");
    downloadAppliance($c, "pve1", "local", $apps[0].template);
    def seen as list of Seen init finish($f);
    testing.assertEqual($all[0].format, "iso");
    testing.assertEqual($seen[0].query, "");
    testing.assertEqual($seen[1].path, "/api2/json/nodes/pve1/storage/local/download-url");
    testing.assertEqual(
        uri.parseQuery($seen[1].body)["url"],
        "https://cdimage.debian.org/x/debian-12.iso");
    testing.assertEqual(uri.parseQuery($seen[1].body)["content"], "iso");
    testing.assertEqual($apps[0].os, "debian-12");
    testing.assertEqual($seen[3].path, "/api2/json/nodes/pve1/aplinfo");
    testing.assertEqual(
        $seen[3].body,
        "storage=local&template=debian-12-standard_12.7-1_amd64.tar.zst");
    testing.assertThrows("downloadADisk", ERROR_KIND);
}

func testCloudInit() {
    def ci as CloudInit;
    $ci.user = "ada";
    $ci.sshKeys = ["ssh-ed25519 AAAAC3Nz ada@laptop\n", "  ", "ssh-rsa AAAAB3Nz ci@build"];
    $ci.ipConfig = ["ip=dhcp", "ip=10.0.0.5/24,gw=10.0.0.1"];
    $ci.nameserver = "10.0.0.1 1.1.1.1";
    def params as map of string to string init cloudInitParams($ci);
    testing.assertEqual($params["ciuser"], "ada");
    testing.assertEqual(maps.has($params, "cipassword"), false);
    testing.assertEqual(
        $params["sshkeys"],
        "ssh-ed25519%20AAAAC3Nz%20ada%40laptop%0Assh-rsa%20AAAAB3Nz%20ci%40build");
    testing.assertEqual($params["ipconfig1"], "ip=10.0.0.5/24,gw=10.0.0.1");
    testing.assertEqual(maps.has($params, "searchdomain"), false);
    def f as Fake init fake([ok("null")]);
    setCloudInit(tokenClient($f), sample("qemu"), $ci);
    def seen as list of Seen init finish($f);
    testing.assertEqual($seen[0].method, "PUT");
    testing.assertEqual(uri.parseQuery($seen[0].body)["sshkeys"], $params["sshkeys"]);
    testing.assertThrows("cloudInitOnAContainer", ERROR_KIND);
}

func testTasksStatusAndMetrics() {
    def f as Fake init fake([
        ok('[{"upid":"' + UPID + '","node":"pve1","type":"qmstart","id":"101","user":"root@pam",' +
            '"starttime":1762045200,"endtime":1762045202,"status":"OK"},' +
            '{"upid":"UPID:pve2:1:2:3:vzdump::root@pam:","node":"pve2","type":"vzdump",' +
            '"starttime":1}]'),
        ok('{"uptime":86400,"pveversion":"pve-manager/8.2.4"}'),
        ok('[{"time":1762045200,"cpu":0.05}]'),
        ok('[{"time":1762045200,"cpu":0.5}]')
    ]);
    def c as Client init tokenClient($f);
    def ts as list of Task init recentTasks($c);
    def st as json.Value init nodeStatus($c, "pve1");
    def nm as json.Value init nodeMetrics($c, "pve1", "hour");
    def gm as json.Value init guestMetrics($c, sample("qemu"), "week");
    def seen as list of Seen init finish($f);
    testing.assertEqual($ts[0].status, "stopped");
    testing.assertEqual($ts[0].exitStatus, "OK");
    testing.assertEqual($ts[1].status, "running");
    testing.assertEqual($ts[1].exitStatus, "");
    testing.assertEqual(json.asInt($st, "/uptime"), 86400);
    testing.assertEqual(json.length($nm), 1);
    testing.assertEqual(json.asFloat($gm, "/0/cpu"), 0.5);
    testing.assertEqual($seen[2].path, "/api2/json/nodes/pve1/rrddata");
    testing.assertEqual($seen[2].query, "timeframe=hour");
    testing.assertEqual($seen[3].path, "/api2/json/nodes/pve1/qemu/101/rrddata");
    testing.assertThrows("badTimeframe", ERROR_KIND);
}

func testPoolsAndHa() {
    def f as Fake init fake([
        ok('[{"poolid":"lab","comment":"test machines"}]'),
        ok("null"),
        ok("null"),
        ok("null"),
        ok('[{"sid":"vm:101","state":"started","group":"prefer-pve1","type":"vm"}]'),
        ok("null"),
        ok("null")
    ]);
    def c as Client init tokenClient($f);
    def ps as list of Pool init pools($c);
    createPool($c, "lab2", "");
    addToPool($c, "lab2", [101, 200]);
    deletePool($c, "lab2");
    def ha as list of HaResource init haResources($c);
    enableHa($c, sample("lxc"), "started");
    disableHa($c, sample("qemu"));
    def seen as list of Seen init finish($f);
    testing.assertEqual($ps[0], Pool{poolid: "lab", comment: "test machines"});
    testing.assertEqual($seen[1].body, "poolid=lab2");
    testing.assertEqual($seen[2].path, "/api2/json/pools/lab2");
    testing.assertEqual($seen[2].body, "vms=101%2C200");
    testing.assertEqual($seen[3].method, "DELETE");
    testing.assertEqual($ha[0], HaResource{sid: "vm:101", state: "started", group: "prefer-pve1"});
    testing.assertEqual($seen[5].body, "sid=ct%3A101&state=started");
    testing.assertEqual($seen[6].path, "/api2/json/cluster/ha/resources/vm:101");
}

func testFirewall() {
    def f as Fake init fake([
        ok('[{"pos":0,"type":"in","action":"ACCEPT","enable":1,"macro":"SSH",' +
            '"source":"10.0.0.0/24"},' +
            '{"pos":1,"type":"in","action":"DROP","proto":"tcp","dport":"3306"}]'),
        ok("null"),
        ok("null")
    ]);
    def c as Client init tokenClient($f);
    def rules as list of FirewallRule init firewallRules($c, sample("qemu"));
    def r as FirewallRule;
    $r.type = "in";
    $r.action = "ACCEPT";
    $r.proto = "tcp";
    $r.dport = "443";
    $r.comment = "https";
    addFirewallRule($c, sample("qemu"), $r);
    deleteFirewallRule($c, sample("qemu"), 1);
    def seen as list of Seen init finish($f);
    testing.assertEqual($rules[0].macro, "SSH");
    testing.assertEqual($rules[0].enable, true);
    testing.assertEqual($rules[1].enable, false);
    testing.assertEqual($rules[1].dport, "3306");
    testing.assertEqual($seen[1].path, "/api2/json/nodes/pve1/qemu/101/firewall/rules");
    def form as map of string to string init uri.parseQuery($seen[1].body);
    testing.assertEqual($form["enable"], "1");
    testing.assertEqual($form["dport"], "443");
    testing.assertEqual(maps.has($form, "source"), false);
    testing.assertEqual($seen[2].path, "/api2/json/nodes/pve1/qemu/101/firewall/rules/1");
}

func testUsersAndPermissions() {
    def f as Fake init fake([
        ok('[{"userid":"root@pam","enable":1,"expire":0},{"userid":"ada@pve","enable":0,' +
            '"email":"ada@example.com","expire":1793581200},{"userid":"bob@pve"}]'),
        ok('[{"path":"/vms/101","type":"user","ugid":"ada@pve","roleid":"PVEVMUser",' +
            '"propagate":1}]'),
        ok("null"),
        ok("null")
    ]);
    def c as Client init tokenClient($f);
    def us as list of User init users($c);
    def acl as list of Acl init permissions($c);
    grant(
        $c,
        Acl{path: "/pool/lab", type: "group", ugid: "devs", roleid: "PVEVMAdmin", propagate: true});
    revoke($c, $acl[0]);
    def seen as list of Seen init finish($f);
    testing.assertEqual($us[0].enabled, true);
    testing.assertEqual($us[1].enabled, false);
    testing.assertEqual($us[1].expire, 1793581200);
    testing.assertEqual($us[2].enabled, true);
    testing.assertEqual($acl[0].roleid, "PVEVMUser");
    testing.assertEqual($acl[0].propagate, true);
    testing.assertEqual($seen[2].method, "PUT");
    testing.assertEqual($seen[2].path, "/api2/json/access/acl");
    def g as map of string to string init uri.parseQuery($seen[2].body);
    testing.assertEqual($g["groups"], "devs");
    testing.assertEqual($g["propagate"], "1");
    def r as map of string to string init uri.parseQuery($seen[3].body);
    testing.assertEqual($r["users"], "ada@pve");
    testing.assertEqual($r["delete"], "1");
    testing.assertThrows("grantToARole", ERROR_KIND);
}

func testReviewFixes() {
    testing.assertEqual(baseUrl("fd00::5"), "https://[fd00::5]:8006");
    def bare as Client;
    testing.assertEqual(pollDelay($bare), 1000);
    testing.assertEqual(pollDelay(withPollInterval($bare, 5)), 5);
    testing.assertEqual(isLocalAddress("169.254.10.1"), true);
    testing.assertEqual(isLocalAddress("FEBF::1"), true);
    testing.assertEqual(isLocalAddress("fec0::1"), false);
    testing.assertEqual(isLocalAddress("10.0.0.1"), false);
    def d as json.Value init json.decode('[{"type":"qemu","vmid":1,"tags":"web prod,eu;x"}]');
    testing.assertEqual(guestFrom($d, "/0").tags, ["web", "prod", "eu", "x"]);
}

func testRestoreFromBackupServer() {
    def f as Fake init fake([upidReply(), upidReply()]);
    def c as Client init tokenClient($f);
    restore($c, "pve1", 150, "pbs:backup/vm/101/2026-11-02T01:00:00Z", "local-lvm");
    restore($c, "pve1", 250, "pbs:backup/ct/200/2026-11-02T01:00:00Z", "");
    def seen as list of Seen init finish($f);
    testing.assertEqual($seen[0].path, "/api2/json/nodes/pve1/qemu");
    testing.assertEqual(
        uri.parseQuery($seen[0].body)["archive"],
        "pbs:backup/vm/101/2026-11-02T01:00:00Z");
    testing.assertEqual($seen[1].path, "/api2/json/nodes/pve1/lxc");
    testing.assertEqual(uri.parseQuery($seen[1].body)["restore"], "1");
}

func ticketWithSemicolon() {
    withTicket(client("pve"), "PVE:root@pam:1::a;b", "c");
}

func ticketWithNewline() {
    withTicket(client("pve"), "PVE:root@pam:1::a\nb", "c");
}

/**
 * A ticket issued some seconds ago.
 *
 * @param age {int} its age in seconds
 * @return {string} the ticket
 */
func ticketAged(age as int) {
    return "PVE:root@pam:" + strings.upper(convert.toString(time.unix(time.now()) - $age, 16)) +
        "::sig";
}

func testTicketsAreCheckedForTheCookie() {
    testing.assertThrows("ticketWithSemicolon", ERROR_KIND);
    testing.assertThrows("ticketWithNewline", ERROR_KIND);
    testing.assertEqual(ticketIssued("PVE:root@pam:66F0A1B2::sig"), 1727046066);
    testing.assertEqual(ticketIssued("PVE:root@pam:nothex::sig"), -1);
    testing.assertEqual(ticketIssued("junk"), -1);
}

func testFresh() {
    def token as Client init withToken(client("pve"), "root@pam!ci", "s");
    testing.assertEqual(fresh($token), $token);
    def young as Client init withTicket(client("pve"), ticketAged(600), "c");
    testing.assertEqual(fresh($young), $young);
    def f as Fake init fake([ok('{"ticket":"' + ticketAged(0) + '","CSRFPreventionToken":"c2"}')]);
    def old as Client init withTicket(client($f.url), ticketAged(4000), "c");
    def renewed as Client init fresh($old);
    def seen as list of Seen init finish($f);
    testing.assertEqual($renewed.csrf, "c2");
    testing.assertEqual($seen[0].path, "/api2/json/access/ticket");
    try {
        fresh(withTicket(client("pve"), ticketAged(8000), "c"));
        missed("an expired ticket was renewed");
    } catch (e) {
        testing.assertTrue(strings.contains($e.message, "log in again"));
    }
}

func testWaitTaskRetriesOutagesButNotRefusals() {
    def f as Fake init fake([
        Reply{status: 502, body: ""},
        Reply{status: 503, body: ""},
        ok('{"status":"stopped","exitstatus":"OK"}'),
        Reply{status: 401, body: '{"data":null}'}
    ]);
    def c as Client init withPollInterval(tokenClient($f), 1);
    def t as Task init waitTask($c, UPID, 0);
    try {
        waitTask($c, UPID, 0);
        missed("a 401 was retried");
    } catch (e) {
        testing.assertTrue(strings.contains($e.message, "HTTP 401"));
    }
    finish($f);
    testing.assertEqual($t.exitStatus, "OK");
}

func testWaitTaskGivesUpAfterTooManyFailures() {
    def replies as list of Reply init [];
    for (def i in lists.range(0, MAX_POLL_FAILURES)) {
        $replies[] = Reply{status: 500, body: '{"data":null,"message":"no such task"}'};
    }
    def f as Fake init fake($replies);
    try {
        waitTask(withPollInterval(tokenClient($f), 1), UPID, 0);
        missed("waitTask retried for ever");
    } catch (e) {
        testing.assertTrue(strings.contains($e.message, "HTTP 500: no such task"));
    }
    def seen as list of Seen init finish($f);
    testing.assertEqual(len($seen), MAX_POLL_FAILURES);
}

func testDescribeHidesTheSecret() {
    def token as Client init withToken(client("pve"), "root@pam!ci", "0b1c-secret");
    testing.assertEqual(describe($token), "https://pve:8006 (API token root@pam!ci)");
    def ticket as Client init withInsecure(withTicket(client("pve"), "PVE:ada@pve:1::sig", "c"));
    testing.assertEqual(
        describe($ticket),
        "https://pve:8006 (ticket for ada@pve, certificate not checked)");
    testing.assertEqual(describe(client("pve")), "https://pve:8006 (no credential)");
}
