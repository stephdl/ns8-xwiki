# ns8-xwiki

[XWiki](https://www.xwiki.org/) module for [NethServer 8](https://github.com/NethServer/ns8-core).

Runs XWiki 18.5.0 (MariaDB/Tomcat flavour) as a rootless Podman pod alongside
MariaDB 11.4. The pod uses slirp4netns networking so XWiki can reach the NS8
LDAP account provider on the host without any extra firewall rules.

## Architecture

| Container | Image |
|-----------|-------|
| `xwiki-app` | `docker.io/xwiki:18.5.0-mariadb-tomcat` |
| `mariadb-app` | `docker.io/mariadb:11.4.12` |

Configuration files mounted into the XWiki container at startup:

- `state/xwiki.cfg` — generated/updated by `bin/generate-xwiki-cfg`
- `state/xwiki.properties` — generated/updated by `bin/generate-xwiki-properties`

### Networking — LDAP access

The pod is created with:

```
--network=slirp4netns:allow_host_loopback=true
--add-host=accountprovider:10.0.2.2
```

This allows XWiki to connect to the NS8 LDAP proxy on the host using the
hostname `accountprovider`. LDAP and SMTP are **not** auto-configured —
configure them manually through the XWiki administration UI after installation.

### Config generation at startup

`bin/generate-xwiki-cfg` (runs as `ExecStartPre` in `xwiki-app.service`):
- sets `xwiki.home` to the public URL behind Traefik
- sets `xwiki.superadminpassword` from `state/passwords.env`
- injects the default plugin list if `xwiki.cfg` predates the image-extraction fix

`bin/generate-xwiki-properties` (runs as `ExecStartPre` in `xwiki-app.service`):
- ensures `extension.repositories` is present so the Extension Manager can
  reach the XWiki Maven repository and extension registry

## Install

```
add-module ghcr.io/nethserver/xwiki:latest 1
```

Example output:

```json
{"module_id":"xwiki1","image_name":"xwiki","image_url":"ghcr.io/nethserver/xwiki:latest"}
```

## Configure

Module instance is named `xwiki1`. Launch `configure-module`:

```bash
api-cli run configure-module --agent module/xwiki1 --data - <<EOF
{
  "host": "xwiki.domain.com",
  "http2https": true,
  "lets_encrypt": false,
  "java_heap_mb": 1024
}
EOF
```

Parameters:

| Parameter | Type | Description |
|-----------|------|-------------|
| `host` | string | FQDN for XWiki (e.g. `xwiki.domain.com`) |
| `http2https` | bool | Redirect HTTP → HTTPS |
| `lets_encrypt` | bool | Request a Let's Encrypt certificate |
| `java_heap_mb` | int | JVM max heap in MB (1024–8192, default 1024) |

The command configures Traefik and restarts XWiki with the new settings.

## Get configuration

```bash
api-cli run get-configuration --agent module/xwiki1
```

## Uninstall

```bash
remove-module --no-preserve xwiki1
```

## Debug

CLI runs under the agent environment. To enter it:

```bash
runagent -m xwiki1
```

Check running containers:

```bash
podman ps
```

Example:

```
CONTAINER ID  IMAGE                                    COMMAND               CREATED        STATUS        NAMES
...           localhost/podman-pause:...               ...                   9 minutes ago  Up 9 minutes  xwiki-infra
...           docker.io/xwiki:18.5.0-mariadb-tomcat   catalina.sh run       9 minutes ago  Up 9 minutes  xwiki-app
...           docker.io/mariadb:11.4.12                --character-set-...   9 minutes ago  Up 9 minutes  mariadb-app
```

Inspect environment inside the XWiki container:

```bash
podman exec xwiki-app env
```

Open a shell:

```bash
podman exec -ti xwiki-app bash
```

XWiki logs:

```bash
podman logs -f xwiki-app
```

## Testing

```bash
./test-module.sh <NODE_ADDR> ghcr.io/nethserver/xwiki:latest
```

Tests are in `tests/xwiki.robot` (Robot Framework). They run in order:
install → configure → verify → uninstall.

## Translation

Translated with [Weblate](https://hosted.weblate.org/projects/ns8/).
