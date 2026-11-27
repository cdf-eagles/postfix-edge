[![CI](https://github.com/cdf-eagles/postfix-edge/actions/workflows/ci.yaml/badge.svg)](https://github.com/cdf-eagles/postfix-edge/actions/workflows/ci.yaml)
[![pre-commit](https://img.shields.io/badge/pre--commit-enabled-brightgreen?logo=pre-commit)](https://github.com/pre-commit/pre-commit)
[![License: BSD-3-Clause](https://img.shields.io/badge/license-BSD--3--Clause-blue.svg)](LICENSE)

# postfix-edge

A container image that runs [Postfix](https://www.postfix.org/) as an inbound edge mail transfer agent (MTA): it accepts mail on port 25 for a set of domains, from a set of trusted networks only, and hands it to a mailbox server over the Local Mail Transfer Protocol (LMTP). Any LMTP backend works, for example Stalwart, Dovecot, or Cyrus IMAP.

The image does not deliver mail anywhere else, does not deliver locally, and offers no authentication. Authenticated submission (ports 465 and 587) belongs on the mailbox server, which already holds the accounts.

## Image

```shell
podman pull ghcr.io/cdf-eagles/postfix-edge:latest
```

The image is built for `linux/amd64` and `linux/arm64` on Alpine Linux. CI builds and tests each architecture on its own native runner, on every push to `main` and weekly, so the weekly build picks up Alpine's security fixes.

| Tag | Meaning |
| --- | --- |
| `latest` | The newest build. |
| `<postfix version>` (for example `3.11.8`) | The newest build of that Postfix release. |
| `<postfix version>-<YYYYMMDD>` | One build, never moved. Pin this tag, or a digest, in production. |
| `latest-amd64`, `latest-arm64` | The newest build for a single architecture. |

Postfix's own release numbers the tags. The image carries no version of its own, so the tags have no semantic version.

### Verifying an image

Every published index carries a build provenance attestation signed through Sigstore. To check it with the GitHub command-line interface (CLI):

```shell
gh attestation verify oci://ghcr.io/cdf-eagles/postfix-edge:latest --repo cdf-eagles/postfix-edge
```

## Configuration

The entrypoint builds `main.cf` from the environment at every start, then runs `postfix start-fg`. It refuses to start, with exit code 64 and a message, when a setting is missing or malformed.

| Variable | Default | Meaning |
| --- | --- | --- |
| `POSTFIX_EDGE_DOMAINS` | required | Domains to accept mail for, separated by commas or spaces (`relay_domains`). |
| `POSTFIX_EDGE_HOSTNAME` | `mail.<first domain>` | The host name in the banner and in `Received:` headers (`myhostname`). |
| `POSTFIX_EDGE_LMTP` | `inet:127.0.0.1:24` | The LMTP backend, as `inet:<host>:<port>` or `unix:<path>`. |
| `POSTFIX_EDGE_MYNETWORKS` | `127.0.0.0/8` | Networks allowed to send, in Postfix `mynetworks` syntax. All other clients are refused. |
| `POSTFIX_EDGE_TLS` | `may` | Postfix's own `smtpd_tls_security_level` names. `may`: STARTTLS is offered and not required. `encrypt`: STARTTLS is required before `MAIL`. Both need the certificate and key. `none`: no STARTTLS. |
| `POSTFIX_EDGE_TLS_CERT` | `/etc/postfix-edge/tls/tls.crt` | Certificate chain, in PEM format. |
| `POSTFIX_EDGE_TLS_KEY` | `/etc/postfix-edge/tls/tls.key` | Private key, in PEM format. |
| `POSTFIX_EDGE_VERIFY_RECIPIENTS` | `yes` | `yes`: Postfix asks the backend whether a recipient exists before accepting it (`reject_unverified_recipient`), so mail for unknown users is refused at the SMTP stage. `no`: the backend refuses it later, and Postfix sends a bounce. |

The default certificate paths match the keys of a Kubernetes `kubernetes.io/tls` Secret, so the Secret can be mounted at `/etc/postfix-edge/tls`.

Any other Postfix setting can be set or replaced with files named `*.cf` in `/etc/postfix-edge/main.cf.d/`, for example from a ConfigMap. Each line is `name = value`; blank lines and lines starting with `#` are skipped. The files are applied in name order, after the settings above. The defaults are in [`rootfs/etc/postfix-edge/main.cf.defaults`](rootfs/etc/postfix-edge/main.cf.defaults).

### What the defaults enforce

- Only clients in `POSTFIX_EDGE_MYNETWORKS` may send (`smtpd_client_restrictions`), and only to recipients in `POSTFIX_EDGE_DOMAINS` themselves, not their subdomains (`smtpd_relay_restrictions = reject_unauth_destination`, with `relay_domains` left out of `parent_domain_matches_subdomains`), so the image is never an open relay.
- Mail for other domains, and local delivery, go to Postfix's `error` transport.
- STARTTLS is offered and not required (`POSTFIX_EDGE_TLS=may`), because the devices that send to port 25 on an internal network often cannot use TLS; `encrypt` requires it. Only TLS 1.2 and later are accepted.
- `VRFY` is disabled, `HELO` or `EHLO` is required, and Simple Authentication and Security Layer (SASL) authentication is off.
- Postfix logs to standard output.

Check which client address Postfix sees before you widen `POSTFIX_EDGE_MYNETWORKS`. Port forwarding that rewrites the source address, such as Docker's userland proxy or rootless Podman's `rootlessport` with slirp4netns, makes every client appear to come from an address inside the container's network, and a `mynetworks` that covers that address admits everyone. The `connect from` lines in the log show the address Postfix sees.

### Volumes

| Path | Purpose |
| --- | --- |
| `/etc/postfix-edge/tls` | Certificate and key, read-only. |
| `/etc/postfix-edge/main.cf.d` | Optional overrides, read-only. |
| `/var/spool/postfix` | The mail queue. Mount a persistent volume so queued mail survives a restart; the entrypoint creates the queue directories on an empty volume. |

## Running

With Podman, next to a backend that listens on LMTP at port 24 of the same pod:

```shell
podman run -d --name postfix-edge --pod mail \
  --cap-drop ALL --cap-add CHOWN --cap-add DAC_OVERRIDE --cap-add FOWNER \
  --cap-add SETUID --cap-add SETGID --cap-add NET_BIND_SERVICE \
  -e POSTFIX_EDGE_DOMAINS=example.internal \
  -e POSTFIX_EDGE_MYNETWORKS="127.0.0.0/8 192.0.2.0/24" \
  -v /path/to/tls:/etc/postfix-edge/tls:ro \
  -v postfix-queue:/var/spool/postfix \
  ghcr.io/cdf-eagles/postfix-edge:latest
```

Postfix's master process runs as root and starts its services as the `postfix` user, so the container runs as root. The capabilities above are the set the smoke test runs with: `CHOWN` and `FOWNER` let the entrypoint create the queue directories on an empty volume, `SETUID` and `SETGID` let Postfix drop to its own user, and `DAC_OVERRIDE` lets the master process reach the queue. `NET_BIND_SERVICE` binds port 25 where the runtime does not already allow unprivileged ports.

[`examples/pod.yaml`](examples/pod.yaml) shows the same setup as a pod for `podman kube play` or Kubernetes, with the certificate in a Secret and an override in a ConfigMap.

To print the configuration a set of variables produces, give a command after the image; the entrypoint renders `main.cf` and runs the command instead of Postfix:

```shell
podman run --rm -e POSTFIX_EDGE_DOMAINS=example.internal -e POSTFIX_EDGE_TLS=none \
  ghcr.io/cdf-eagles/postfix-edge:latest postconf -n
```

## Health check

The image declares a health check, so Docker and Podman report the service's state without any setup. Every 30 seconds (10-second timeout, 20-second start period, 3 retries) it runs `postfix-edge-healthcheck`, which passes when Postfix's master process runs and port 25 completes an SMTP handshake: the `220` banner, a `250` reply to `EHLO`, and a `221` reply to `QUIT`.

```shell
docker inspect --format '{{.State.Health.Status}}' postfix-edge
podman healthcheck run postfix-edge && echo healthy
```

Podman reads a health check only from an image in Docker format. The published images are in Docker format; build your own with `podman build --format docker`.

The health check does not depend on the LMTP backend, so a backend outage never marks Postfix unhealthy and restarts it while mail could wait in the queue. `postfix-edge-healthcheck --backend` also requires the backend to answer `LHLO`, for an `inet:` target only; use it where a failure only takes the service out of rotation, such as a Kubernetes readiness probe, not as a liveness check.

Each check opens one SMTP session, so the log gains a `connect` and a `disconnect` line every 30 seconds.

## Development

`scripts/smoke-test.sh` runs the image with a small LMTP server ([`tests/lmtp_sink.py`](tests/lmtp_sink.py)) in its network namespace and checks the configuration refusals, the declared health check and its result with and without the backend, the banner, STARTTLS, that no AUTH is offered, relay refusal (another domain and a subdomain), unknown-recipient refusal, delivery over LMTP, refusal of a client outside `mynetworks`, mandatory STARTTLS with `POSTFIX_EDGE_TLS=encrypt`, and a clean stop. It needs Podman or Docker and `openssl`:

```shell
podman build --format docker -t localhost/postfix-edge:dev .
sh scripts/smoke-test.sh localhost/postfix-edge:dev
```

Linting runs through [pre-commit](https://pre-commit.com/) (`pre-commit run --all-files`), with the tool versions pinned in `ci/requirements.txt` and `.pre-commit-config.yaml`.

## Licenses

The files in this repository are under the [BSD 3-Clause license](LICENSE).

The published image also contains software that keeps its own license: Postfix (IBM Public License 1.0 or Eclipse Public License 2.0, at the recipient's choice) and the Alpine Linux packages it runs on, among them BusyBox and apk-tools (GNU General Public License 2.0), musl (MIT), and OpenSSL (Apache 2.0). The image holds no Linux kernel; a container runs on its host's kernel. To list every package in an image with its license:

```shell
podman run --rm --entrypoint apk ghcr.io/cdf-eagles/postfix-edge:latest list --installed
```

The source of each package is in Alpine's [aports repository](https://gitlab.alpinelinux.org/alpine/aports) on the branch of the image's Alpine release (`3.24-stable`), whose build files name each upstream source archive, and Postfix's own source is at [postfix.org](https://www.postfix.org/).
