# Incident notes

I left the bsf-shop plugin alone. The slow report, the big export and the lookup query are all in there on purpose, and the fix belongs in the platform around them.

The 502 hides a few of the others. Until PHP is actually reachable you can't see the redirect loop, the export, or the object cache screen.

---

## Issue 1: whole site returns 502

- **Symptom:** https://localhost:8443 is a 502 Bad Gateway. Not a WordPress error page, so PHP never ran.
- **How I found it:** `web/default.conf` has `fastcgi_pass wordpress:9001`. I assumed the pool size first (`pm.max_children = 1`), but a busy pool shows up as timeouts and a queue, not as "nothing is listening". The official php-fpm image writes `listen = 9000` in `zz-docker.conf`. Our `zz-bsf-pool.conf` never changes `listen`, and it sorts before `zz-docker.conf` anyway, so it couldn't override that. Nginx is calling a port with no process on it.
- **Root cause:** the vhost points at 9001. php-fpm is on 9000. Connection refused becomes a 502, on every request, including ones that would otherwise have been fine.
- **Fix:** `fastcgi_pass wordpress:9000`. Commit `d06566f`.
- **Prevention:** a container healthcheck that requests `/` through nginx, not just "is the php-fpm process up". And don't hardcode a port that isn't in our own config. `php-fpm -tt` inside the wordpress container prints the listen line.

---

## Issue 2: too many redirects on wp-admin

- **Symptom:** browser error, too many redirects, on wp-admin. The front page does the same once the 502 is gone, because the site URL is https.
- **How I found it:** `WP_HOME` and `WP_SITEURL` are `https://localhost:8443`, and `FORCE_SSL_ADMIN` is on. The edge proxy terminates TLS and then talks plain HTTP to `web:80`. It set `Host` and `X-Real-IP` and did not set `X-Forwarded-Proto`. WordPress `is_ssl()` looks at `HTTPS` or port 443. Both say this is HTTP, so wp-admin redirects to the https URL the browser is already on.
- **Root cause:** TLS stops at the edge, and nothing tells PHP that. Turning `FORCE_SSL_ADMIN` off would make the loop go away and would also be the wrong fix.
- **Fix:** edge sets `X-Forwarded-Proto` from `$scheme` (the connection it actually accepted, not the client header, so it can't be spoofed on :80, and :80 just 301s to https). The WordPress vhost maps that to `fastcgi_param HTTPS`. Commit `a47e6c9`.
- **Prevention:** after any proxy change, `curl -kI https://localhost:8443/wp-admin/` and count `Location` headers. One redirect to the login form is normal. More than two is a loop. Keep this in a smoke test.

---

## Issue 3: sales report hangs the site for everyone

- **Symptom:** opening `/?bsf=report` and the rest of the site stalls until that request is done.
- **How I found it:** the plugin `sleep(8)`s to fake a slow analytics API. We're not allowed to delete that. The pool file is `pm = static` and `pm.max_children = 1`, with `request_terminate_timeout = 60s`. One worker is the whole site. Nginx's `fastcgi_read_timeout` is 15s, which is enough for an 8s sleep plus WordPress boot, so raising timeouts would not have fixed "everyone else hangs".
- **Root cause:** a single PHP worker. The report holds it, and every other request waits on that same worker.
- **Fix:** `pm = dynamic` with `max_children = 5`, 2 started, spare servers 1 to 3. The person who opened the report still waits ~8s. Other requests get a free worker. I didn't bump the 15s timeout. Commit `2924a9d`.
- **Prevention:** alert when php-fpm idle workers are 0, or when the listen queue is non-zero. A pool of 1 should not survive a review. The slowlog is already on at 3s, so the report will keep showing up there, which is what we want.

---

## Issue 4: export orders is a blank page

- **Symptom:** `/?bsf=export` comes back blank, or a 502 if the worker dies mid-request.
- **How I found it:** the plugin loads `SELECT * ... LIMIT 50000` into a PHP array (`ARRAY_A`) and then writes CSV. `notes` is 120 characters on every row. `php_admin_value[memory_limit] = 48M`, and `WP_DEBUG_DISPLAY` is false, so the fatal goes to the log and the browser gets an empty response. `php_admin_value` also means a plugin can't `ini_set` its way out of this, which is fine, we weren't going to edit the plugin.
- **Root cause:** 48M is not enough to hold 50k rows of that shape in PHP arrays. WordPress itself already uses a chunk of it.
- **Fix:** memory limit 256M. One export is allowed to be heavy. Normal page views are not. Commit `367cd0a`.
- **Prevention:** the debug log (now under `/tmp`, see issue 8) should be shipped somewhere we actually look, and "Allowed memory size exhausted" should page. 48M is a strange production value for Woo-style exports.

---

## Issue 5: order lookup takes forever

- **Symptom:** `/?bsf=orders&email=customer42@example.com` sits there. It isn't one query, the page also looks up 5 more "recent customers".
- **How I found it:** the plugin query is `WHERE customer_email = ? ORDER BY created_at DESC LIMIT 10`. `db/init/10-bsf-orders.sql` creates `wp_bsf_orders` with only `PRIMARY KEY (id)` and then inserts 2,000,000 rows. No index can satisfy that WHERE. Six full scans. Slow log is already on at 0.1s, so this is what it would be full of. `EXPLAIN` would say `type: ALL`.
- **Root cause:** missing secondary index. The query is fine. The table isn't.
- **Fix:** index `(customer_email, created_at)` so the filter and the sort are the same index. Added in `db/init/30-bsf-orders-index.sql` after the seed (indexing 2M rows during the insert would just make first boot slower). `setup.sh` adds it too if the volume was created before that file existed. Commit `62b9ae4`.
- **Prevention:** when a plugin ships a new table, `EXPLAIN` the queries it actually runs before it sees production data. The slow log was already configured. Nobody has to be watching it for this one to be obvious on day two.

---

## Issue 6: /app fails on some refreshes

- **Symptom:** https://localhost:8443/app works, then a refresh 502s, then it works again.
- **How I found it:** edge upstream is `app1:3000` and `app2:3000`, round robin, and `proxy_next_upstream off`. app1's `PORT` is 3000. app2's `PORT` is 3001. Next's standalone server listens on `PORT`, so app2 is on 3001 and nothing is on app2:3000. About half the requests are connection refused, and nginx is told not to try the other instance.
- **Root cause:** app2 was given a different port, as if the two containers shared a host port. They don't. Each has its own network namespace.
- **Fix:** app2 `PORT=3000`, same as app1, which is what the upstream already expected. I also set `proxy_next_upstream error timeout http_502 http_503` so a restart of one app doesn't 502 the user. That is not the fix for this bug. If I'd only flipped that flag, app1 would have hidden a dead app2. Commit `7733b84`.
- **Prevention:** hit each upstream directly, not only through the load balancer. `/app/api/health` already returns `INSTANCE_NAME`. A check that both names show up catches this. Don't treat "the page loads" as proof both backends are alive when the proxy is allowed to retry.

---

## Issue 7: object cache plugin errors

- **Symptom:** the Redis object cache plugin in wp-admin reports errors. The site still loads because `WP_REDIS_GRACEFUL` is true, so this one looks smaller than it is.
- **How I found it:** `redis.conf` had `maxmemory 1mb` and `maxmemory-policy noeviction`. WordPress fills 1mb of cache keys almost immediately. `noeviction` means the next `SET` gets `OOM command not allowed` instead of Redis dropping an old key. The plugin surfaces that.
- **Root cause:** the cache is configured like a database that must not lose a key. It's a cache. When it's full it should evict.
- **Fix:** `maxmemory 128mb` and `allkeys-lru`. This instance doesn't store anything we can't rebuild, so evicting a key with no TTL is fine. `volatile-lru` would not help if a key was written without an expiry, and we'd be back to OOM. Commit `6fbf6b5`.
- **Prevention:** graph `evicted_keys` and rejected commands. `noeviction` on a cache should fail review. 1mb on a WordPress cache should too.

---

## Issue 8: .env and the debug log were in the docroot

- **Symptom:** nobody reported this. `scripts/setup.sh` wrote a `.env` into `/var/www/html` with the database password, and `WP_DEBUG_LOG` was `wp-content/debug.log`.
- **How I found it:** reading setup, then the vhost. `location /` is `try_files $uri $uri/ /index.php`, so a request for `/.env` is a static file if it exists. Nginx will happily serve it. Nothing else in this stack reads that file. The comment calls it release tooling. It isn't wired to anything.
- **Root cause:** secrets dropped in the document root, and no rule denying dotfiles.
- **Fix:** stopped writing the file, and setup now deletes `.env` and `wp-content/debug.log` if an older volume still has them. The vhost denies `/.` and `debug.log`. Debug log moved to `/tmp/wp-debug.log`, which is not the docroot. Commit `93c219b` (same commit as the Redis exposure below).
- **Prevention:** base nginx template denies dotfiles. A curl of `/.env` belongs in the smoke test (403, not the file). Don't write credentials into a directory the web server is rooted at.

---

## Issue 9: Redis was published on the host with no password

- **Symptom:** also unreported. `docker compose` published `6379:6379`. The config was `bind 0.0.0.0`, `protected-mode no`, no `requirepass`.
- **How I found it:** same pass as the cache settings. Port publish plus protected mode off means anyone who can reach the machine can read and write the object cache. That's sessions and options, not just a speed layer.
- **Root cause:** the cache was left open so containers could reach it, and the easy version of that was "publish the port and turn protection off".
- **Fix:** removed the host port. `requirepass` plus `WP_REDIS_PASSWORD`. `protected-mode yes`. Still `bind 0.0.0.0`, because `127.0.0.1` inside the Redis container is not reachable from the wordpress container. Other containers on the compose network can connect, and they need the password. Commit `93c219b`.
- **Prevention:** cache ports don't get a `ports:` entry. A review check for `protected-mode no` without a password. From the host, `redis-cli -p 6379 ping` should fail to connect.

---

## Issue 10: the backup job says it worked when the dump didn't

- **Symptom:** `docker compose run --rm backup` exits 0 and uploads a file. That's the problem. I wouldn't trust the file.
- **How I found it:** `backup.sh`. `set -e` does not fail a pipeline in `/bin/sh` unless `pipefail` is on. `mariadb-dump ... | gzip > file` can have a failed dump, gzip of empty stdout still exits 0, and the script uploads it and prints `done`. It also dumped `--all-databases` as MariaDB root, with the password on the process command line, so the object contains the grant tables as well as WordPress. No `--single-transaction`, so the default is a lock and the snapshot isn't a single InnoDB view. The S3 keys in the script are the MinIO root user, which can delete every bucket.
- **Root cause:** success was "gzip produced a file and the upload returned 0", not "the dump succeeded and the object is only a backup of this site".
- **Fix:** commit `b3d1e3d`.
  - `set -o pipefail`, then `gzip -t` before upload. A failed dump fails the job.
  - Dump only `wordpress`, as user `backup` (`db/init/20-backup-user.sql`: `SELECT, SHOW VIEW, TRIGGER, LOCK TABLES` on that database). `--single-transaction --quick`. Password goes in a `0600` client file, not `-p` on the argv.
  - `s3-init` creates bucket `bsf-backups` and user `bsf-backup` with `backup/s3-policy.json`. That user can `PutObject` (and the two multipart calls a big `aws s3 cp` actually makes) under `site-x/*` only. The backup container does not get the MinIO root keys.
  - The job still cannot delete old backups. Expiry belongs on a bucket lifecycle rule, not in a script that has `DeleteObject`.
- **Prevention:** the job's exit code has to be paged on. Once in a while restore a dump onto a scratch database and run `wp db check`. `pipefail` on any script that pipes a dump into a compressor. Init scripts only run on a new data volume, so the backup user shows up after `docker compose down -v` (or a fresh machine). An old volume won't have the user.

---
