# How I used AI

## Tools used

Claude, inside Cursor. I also read the configs myself. The plugin, the compose file, the nginx vhosts, the pool file, redis, and `backup.sh` are not that big.

## How I used them

- Walked the reported symptoms against the files and asked what else could cause the same symptom, so I wouldn't stop at the first match.
- Asked for a review of `backup.sh` specifically around "the script exits 0". That's where pipefail came from. I already didn't like `--all-databases` as root.
- Used it as a second pair of eyes on the S3 policy, mostly to check I hadn't granted `ListBucket` or `DeleteObject` by accident.
- I decided the pool numbers, the memory limit, and what not to change (the plugin, `FORCE_SSL_ADMIN`, the 8 second sleep).

## Key prompts

1. "Wordpress behind an nginx TLS proxy, `FORCE_SSL_ADMIN` on, browser says too many redirects. What's the usual cause and what's a bad fix?"
2. "This backup is `mariadb-dump | gzip` with `set -e` and then `aws s3 cp`. Why would it print done when the dump failed?"
3. "Next.js app, two containers, upstream `app1:3000` and `app2:3000`, app2 has `PORT=3001`, `proxy_next_upstream off`. Why would /app fail on some refreshes only?"
4. "Redis `maxmemory 1mb` and `noeviction` in front of the WordPress object cache. What does the plugin actually show, and is `maxmemory 0` a fix?"

## When the AI was wrong or risky

A few suggestions would have made the ticket go green and left the real bug in place.

- It said to turn `FORCE_SSL_ADMIN` off to kill the redirect loop. That stops the redirects. It also means we "fixed" HTTPS detection by not requiring HTTPS. I kept the flag and passed the scheme from the edge. It sets `X-Forwarded-Proto` from `$scheme`, not from the incoming header.
- It suggested editing `bsf-shop.php`: lower the export `LIMIT`, and add an index hint in the lookup SQL. The README says that plugin is third-party. The export is a memory limit. The lookup is a missing index on `customer_email`. Both are outside the plugin. `memory_limit` is also a `php_admin_value`, so the plugin couldn't raise it anyway.
- For the random `/app` 502s it said to turn `proxy_next_upstream` back on. That would make the page load, by retrying app1, while app2 stayed on the wrong port. I changed app2 to port 3000. The retry is there too, but only so a dead process doesn't take down the request. It is not how I checked the fix. Both upstreams have to be on 3000.
- For the object cache errors it suggested `maxmemory 0` and a `FLUSHALL`. Removing the cap means a noisy plugin can grow Redis until the box is unhappy. `allkeys-lru` with a real cap is the cache config. `noeviction` is what you use when the data isn't a cache.

## What I'd never let an AI do unchecked on a production server

- Restart php-fpm, flush Redis, or `docker compose down -v` because a prompt said the cache was corrupt. That's how you hide the thing you needed to see, or delete the volume.
- Apply a diff that publishes a port, turns `protected-mode` off, or writes a password into the docroot, without reading it line by line. Those were already the bugs in this repo.
- Run a dump or a restore it wrote against the live database. The original backup script is a good example of a command that exits 0 and still isn't a backup.
