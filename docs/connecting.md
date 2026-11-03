<!-- SPDX-License-Identifier: LGPL-3.0-only -->
<!-- SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev> -->

# Connecting

`proxmox.client` takes a host name, `host:port` or a full URL. A bare host
gets `https://` and port 8006, the API's port:

```jennifer
import "@deckyard/proxmox/" as proxmox;

def c as proxmox.Client init proxmox.client("pve.example.com");   # https://pve.example.com:8006
$c = proxmox.withTimeout($c, 30000);
```

## Certificates

A fresh Proxmox host serves a certificate signed by the cluster's own CA. Trust
that CA: copy `/etc/pve/pve-root-ca.pem` from a node and pass it in.

```jennifer
$c = proxmox.withCaCert($c, fs.readBytes("pve-root-ca.pem"));
```

`proxmox.withInsecure($c)` accepts any certificate. The traffic is still
encrypted but anyone in the path can read the credential, so keep it for a lab.

## API tokens

A token is the right credential for a program. Create one under
**Datacenter -> Permissions -> API Tokens**; the id is `user@realm!name`.
Without **Privilege Separation** the token has its user's rights, with it the
token needs its own permissions.

```jennifer
$c = proxmox.withToken($c, "root@pam!automation", os.getEnv("PVE_TOKEN_SECRET"));
```

A token does not expire unless you set a date, and needs no CSRF token.

## Password and ticket

`proxmox.login` posts the user name and password to `/access/ticket` and keeps
the ticket. Every later request carries it as the `PVEAuthCookie` cookie, and
every write adds the `CSRFPreventionToken` header.

```jennifer
$c = proxmox.login($c, "root@pam", os.getEnv("PVE_PASSWORD"));
```

A ticket lasts two hours. `proxmox.renew($c)` trades it for a fresh one while
it is still valid; `proxmox.fresh($c)` does so only once the ticket is older
than an hour, and returns any other client unchanged without a request. A
long-running program calls it before each batch of work:

```jennifer
$c = proxmox.fresh($c);
```

A ticket that has run out cannot be renewed: `fresh` throws and the program
logs in again. A long-running program can keep the ticket and CSRF token
(`$c.ticket`, `$c.csrf`) and restore them later with `proxmox.withTicket`.

An account with a TOTP second factor logs in with the current code:

```jennifer
$c = proxmox.loginTotp($c, "ada@pve", $password, "123456");
```

`proxmox.login` on such an account throws and says to use `loginTotp`.
WebAuthn, recovery keys and Yubico OTP are not supported; use a token.

## Logging a client

A `Client` holds its credential in plain fields: the token secret, or the
ticket, which grants full access for two hours. Never print or log the
client itself. `proxmox.describe($c)` gives a line without the secret:
`https://pve:8006 (API token root@pam!ci)`.

## Any endpoint

The [API viewer](https://pve.proxmox.com/pve-docs/api-viewer/) lists every
endpoint. Call one by its path under `/api2/json`:

```jennifer
def tasks as json.Value init proxmox.get($c, "/cluster/tasks", {});
proxmox.post($c, "/pools", {"poolid": "lab", "comment": "test machines"});
proxmox.put($c, "/nodes/pve1/dns", {"search": "lab.example", "dns1": "10.0.0.1"});
proxmox.delete($c, "/pools/lab", {});
```

`proxmox.call($c, method, path, params)` takes the method as a string. Paths
must start with `/` and hold no `..`, `?`, `#` or `//`, so a path built from
input cannot send the credential elsewhere. Encode a path segment from input
with `uri.encode`.
