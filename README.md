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
  "lets_encrypt": false,
  "java_heap_mb": 1024
}
EOF
```

Parameters:

| Parameter | Type | Description |
|-----------|------|-------------|
| `host` | string | FQDN for XWiki (e.g. `xwiki.domain.com`) |
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


## Migrate from a bare metal installation

These steps migrate an existing XWiki instance installed from the Debian/Ubuntu
packages (`xwiki-tomcat9-mysql` and friends) into this module. The module runs a
newer XWiki release than most bare metal instances, so the migration is a data
move followed by an in-place upgrade performed by XWiki itself.

The procedure assumes the source instance stores attachments on the filesystem,
which is the default (`xwiki.store.attachment.hint=file`). Confirm the permanent
directory location before starting:

```bash
grep -i permanentDirectory /etc/xwiki/xwiki.properties
```

XWiki must not be started against an empty database first: the module is
installed, both volumes are replaced with the source data, and only then is the
instance reached over HTTP so that the Distribution Wizard can upgrade it.

### 1. Export the source instance

Run this on the old server. The database dump can be taken while the wiki is
still serving requests; dump the database first and archive the files
immediately afterwards, so that any attachment uploaded in between ends up as a
harmless orphan file rather than a broken attachment.

```bash
mysqldump --single-transaction --quick \
  --add-drop-database --databases xwiki \
  --default-character-set=utf8mb4 --skip-dump-date \
  --no-tablespaces --set-gtid-purged=OFF > xwiki.sql

tar czf xwiki-data.tar.gz \
  --owner=0 --group=0 --numeric-owner \
  --exclude='data/store/solr' --exclude='data/jobs' \
  --exclude='data/cache' --exclude='data/tmp' --exclude='data/logs' \
  -C /var/lib/xwiki data
```

The dump **must** be named `xwiki.sql`: this is the file name expected by the
restore action used in step 4.

`--no-tablespaces` and `--set-gtid-purged=OFF` are MySQL-only options, drop them
if the source runs MariaDB. `--owner=0 --group=0 --numeric-owner` matters: the
source files belong to the `tomcat` user, and preserving those numeric IDs would
produce a permanent directory that the rootless container cannot write to.

The excluded directories are rebuilt by XWiki on the next start. Leaving out the
Solr index is deliberate — it is rebuilt from scratch against the new version —
and excluding them also avoids `tar` failing on files being written by the live
instance.

Sanity checks before transferring the archives:

```bash
tail -1 xwiki.sql                                   # "-- Dump completed"
grep -c '_0900_' xwiki.sql                          # must be 0
tar tzf xwiki-data.tar.gz | grep -c 'data/store/file/'
tar tzf xwiki-data.tar.gz | grep -c 'data/extension/'
```

A non-zero `_0900_` count means the source uses a MySQL 8 collation that MariaDB
does not know about. XWiki requires a binary collation anyway, so rewrite those
occurrences to `utf8mb4_bin` before importing:

```bash
sed -i 's/utf8mb4_0900_ai_ci/utf8mb4_bin/g; s/utf8mb4_0900_as_cs/utf8mb4_bin/g' xwiki.sql
```

Copy `xwiki.sql` and `xwiki-data.tar.gz` to the NS8 node.

### 2. Install and configure the module

Use the FQDN the wiki will be served on:

```bash
add-module ghcr.io/nethserver/xwiki:latest 1

api-cli run configure-module --agent module/xwiki1 --data - <<'EOF'
{"host":"wiki.example.org","lets_encrypt":true,"java_heap_mb":3072}
EOF
```

Give the JVM some headroom: the schema migrations and the full Solr reindex that
follow are the most memory-hungry moments in the life of the instance. The value
can be lowered again with a second `configure-module` call once the migration is
over.

### 3. Stop the instance and drop both volumes

```bash
runagent -m xwiki1
systemctl --user stop xwiki.service
podman volume rm mysql-data xwiki-data
```

Both volumes have to be replaced as a pair. The database records which
extensions are installed, and `extension/repository` inside the permanent
directory holds their artifacts: mixing the freshly installed state with the
source data leaves extensions referenced on one side and missing on the other,
which makes the Distribution Wizard fail in obscure ways.

Removing `mysql-data` is also what allows the next step to work at all: the
MariaDB entry point only runs `docker-entrypoint-initdb.d` scripts when it
initialises an empty data directory.

### 4. Restore the database


xwiki.sql must be in the path of the $AGENT_STATE_DIR

```bash
runagent -m xwiki1
cp /path/to/xwiki.sql .
../actions/restore-module/40restore_database
```

The action moves `xwiki.sql` into `initdb.d/`, starts a throwaway MariaDB
container against the `mysql-data` volume, replays the dump and shuts down
cleanly. Because the files are sourced in alphabetical order, the module's own
`init.sql` runs before the dump and its global `GRANT` survives the
`DROP DATABASE` contained in the dump — XWiki needs the `PROCESS` privilege,
which a schema-scoped grant would not provide.

### 5. Restore the permanent directory

```bash
podman volume create xwiki-data
podman volume import xwiki-data /path/to/xwiki-data.tar.gz
```

The volume is mounted on `/usr/local/xwiki`, and the archive contains `data/` at
its root, so the files land in `/usr/local/xwiki/data` — exactly where the image
expects the permanent directory.

If the source instance was itself containerised, make sure the archive carries
no `hibernate.cfg.xml`, `xwiki.cfg` or `xwiki.properties` at the root of `data/`.
The image entry point copies those files over `WEB-INF` on every start, and a
stale `hibernate.cfg.xml` would point the new instance at the old database.

### 6. Let XWiki upgrade itself

Point the FQDN at the NS8 node, then start the instance:

```bash
systemctl --user start xwiki.service
```

The first start replays the XWiki schema migrations between the source version
and the version shipped by this module. On a wiki with a long history this takes
a while; do not interrupt it.

Then open `https://wiki.example.org` and log in as `superadmin`, using the
password that was set in the sql databse of the xwiki. XWiki
detects that the wiki content belongs to an older distribution and offers to
upgrade the flavor. Accept it and review the page conflicts it reports rather
than clicking through — pages customised on the source instance are the ones
that need a decision.

Once the wizard is done, go to **Administration → Extensions** and deal with any
extension still reported as invalid. Extensions that became part of XWiki
Standard since the source version, such as the CKEditor integration, are handled
by the wizard but are also where merge conflicts are most likely.

### Note on the context path

The Debian packages serve the wiki under `/xwiki`, while this module deploys it
in the `ROOT` context:

```
before:  https://old.example.org/xwiki/bin/view/Main/WebHome
after:   https://wiki.example.org/bin/view/Main/WebHome
```

Page references stored in the database are unaffected, but bookmarks, external
links and any absolute URL hardcoded in page content will break. Count them
before migrating:

```sql
SELECT COUNT(*) FROM xwikidoc WHERE XWD_CONTENT LIKE '%/xwiki/bin/%';
```
