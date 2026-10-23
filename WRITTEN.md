# Written questions

Short, practical answers are best. Bullet points are fine. Aim for ~30 minutes total.

## 1. Least-privilege S3 access

Our backup job should be able to **upload new files to `s3://bsf-backups/site-x/`** and nothing else: no reading or deleting other backups, no access to other buckets.

a) Write the IAM policy (JSON) you'd attach.
b) The job runs on an EC2 instance / VPS. How should it get credentials? Why is that better than an access key in a script?

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "UploadSiteBackupsOnly",
      "Effect": "Allow",
      "Action": [
        "s3:PutObject",
        "s3:AbortMultipartUpload",
        "s3:ListMultipartUploadParts"
      ],
      "Resource": "arn:aws:s3:::bsf-backups/site-x/*"
    }
  ]
}
```

`PutObject` is the actual upload. I added `AbortMultipartUpload` and `ListMultipartUploadParts` because `aws s3 cp` switches to multipart once the file is bigger than about 8MB, and those two calls are part of finishing or cancelling that upload. They are scoped to keys under `site-x/`. There is no `GetObject`, no `DeleteObject`, and no `ListBucket` on the bucket, so this role can't read or remove an older backup, and it can't see another bucket. It also can't create the bucket. Something else does that once.

If the client is `aws s3 sync` rather than `cp`, it will want `ListBucket` and this policy will correctly refuse. I'd keep the job on `cp` / `PutObject` instead of widening the policy.

b) On EC2, an instance role (instance profile) attached to the box. The job uses the normal AWS credential chain and gets temporary credentials from the instance metadata service. Nothing long-lived sits in the script or in the repo. The creds expire, and you can take the role off the instance without hunting through crontab files. Require IMDSv2 and keep the hop limit at 1, so a random SSRF in WordPress can't just read the role credentials.

A VPS that isn't EC2 doesn't have an instance role. I still wouldn't put an access key in the script. I'd inject a key with this same policy from a secret store at runtime, with the file mode `0600`, or I'd run the job somewhere that actually has a role. The key in `backup.sh` as it was shipped is the thing this question is about.

## 2. Cloudflare "Error 525"

A customer moved their WordPress site to one of our servers. DNS is on Cloudflare (proxied, orange cloud). Since the move, visitors see **Error 525: SSL handshake failed**.

List what you'd check, in order, and what each check tells you.

525 means Cloudflare tried to speak TLS to the origin and the handshake never finished. It is not 526. 526 is "the handshake worked and the certificate is wrong". So I'm looking for "nothing is completing a handshake", not "the cert name doesn't match", at least at first.

1. Cloudflare SSL/TLS mode for the zone. 525 means CF is connecting to the origin with HTTPS, so the mode is Full or Full (strict). Flexible talks HTTP to the origin and wouldn't fail this way. This tells me which port CF is using (443) and whether a broken origin cert is even in play yet.
2. The DNS record. Orange-cloud A/AAAA should be the new server's IP. `dig` it. If it's still the old host, or a load balancer they didn't update, I'm handshaking with the wrong machine and the new server is fine.
3. From outside the server, not from localhost: `openssl s_client -connect ORIGIN_IP:443 -servername customerdomain`. Connection refused, timeout, or reset tells me the handshake isn't getting a TLS listener. A completed handshake tells me the origin is fine from the public internet and I should look at CF's path specifically (different IP, or something that only blocks CF ranges).
4. On the box: `ss -lntp | grep ':443'` and `nginx -T` (or `apachectl -S`). After a move the new vhost is often only on port 80, or the `ssl_certificate` path points at a file that was never copied. `nginx -t` catches a config that isn't actually loaded.
5. The cert files. They exist, the web user can read them, they're not expired (`openssl x509 -in cert -noout -dates -subject`), and the cert and key match (`openssl x509 -noout -modulus` vs `openssl rsa -noout -modulus`). A mismatch fails the handshake. This is also where I notice someone put the key in the cert directive.
6. Firewall on the new server. Security group, ufw, firewalld, CSF, fail2ban. Cloudflare's IP ranges have to reach 443. A drop looks like a timeout. A reject looks like a reset during the handshake. If `openssl` from my laptop works and CF still gets 525, this is the check that explains it.
7. Protocols and ciphers. An origin that only offers TLS 1.0 or 1.1, or an empty `ssl_ciphers` list, fails against current Cloudflare. `ssl_protocols TLSv1.2 TLSv1.3` is the usual fix. The `openssl` output from step 3 shows what the server offered.
8. SNI. Same `openssl` command with and without `-servername`. If the default vhost is a broken SSL stub, CF's SNI might be hitting it and a request without SNI would look different.
9. The origin error log while I reproduce one request. If nothing is logged, the packets aren't arriving (firewall or wrong IP). If nginx logs a handshake error, the packets are arriving and the vhost/cert/protocol is the problem.
10. Only if the handshake succeeds in `openssl` from outside and CF still returns 525: Authenticated Origin Pulls turned on in CF without the origin cert installed, or another proxy in front of nginx that doesn't like CF. I check this last because it's rarer than "443 isn't up on the new box".

## 3. Emails landing in spam

A customer's WooCommerce order emails are sent through **Amazon SES** and are landing in spam for Gmail users.

Which DNS records and SES settings would you check, and what should each look like?

I'd pull one of the Gmail messages and use "Show original" first. The Authentication-Results line says which of SPF, DKIM, DMARC failed. Then I'd check these, in that order.

- SES identity. The domain in the WooCommerce From address is a verified domain identity, not just a single verified mailbox, and the account is out of the sandbox. The reputation dashboard isn't showing a bounce or complaint rate that's already burning the account. If the domain isn't verified, nothing below matters.
- Custom MAIL FROM in SES, set to something like `mail.customerdomain.com`, status verified. The envelope default is `amazonses.com`. SPF can pass for that and still not align with the store's From domain, and DMARC then fails. The two records SES asks for on that subdomain:
  - MX `10 feedback-smtp.<region>.amazonses.com`
  - TXT `v=spf1 include:amazonses.com -all`
- SPF on the From domain itself. One TXT record, not two. It has to include whatever actually sends. If the custom MAIL FROM is in place, the envelope SPF is the one on `mail.customerdomain.com`, and the apex record should not be a second conflicting SPF. `-all` at the end, not `+all`. `dig TXT customerdomain.com` and look for more than one `v=spf1`.
- DKIM. Easy DKIM, the three CNAMEs SES shows, status "successful" in the console. `dig CNAME <selector>._domainkey.customerdomain.com` should land on the `amazonses.com` target SES gave them. In the Gmail original, `dkim=pass` and `d=` should be the store domain, not some other domain a plugin signed with.
- DMARC. TXT on `_dmarc.customerdomain.com`, at least `v=DMARC1; p=none; rua=mailto:dmarc@customerdomain.com` while we're fixing alignment, then `p=quarantine` once pass is steady. `p=none` doesn't stop spam placement by itself. It tells us what is failing. Gmail should show `dmarc=pass`. If SPF and DKIM both pass and DMARC doesn't, it's an alignment problem (From domain vs `d=` vs the envelope), which is the custom MAIL FROM case above.
- They aren't also sending the same mail from the server's own Postfix. Those messages aren't covered by the SES SPF record, and Gmail will treat them differently from the ones that went through SES. WooCommerce should be on the SES SMTP credentials or the API, not `mail()`.

If Show original already says spf=pass, dkim=pass, dmarc=pass and it's still in spam, I'd stop chasing DNS and look at the SES account reputation and the message itself (the shared SES IP pool, a bunch of bounces, or a template that's mostly links). A dedicated IP is only worth it if they send enough for an IP to warm up. It won't fix a broken DKIM record.

## 4. cPanel server at 100% CPU

A shared cPanel/WHM server hosting 40 customer WordPress sites is at 100% CPU. Sites are slow. You have root SSH.

What do you do in your **first 10 minutes**? Be specific about commands/tools and what you're looking for.

I don't reboot. A reboot hides which process it was.

1. `uptime` and `top -c` (or `ps aux --sort=-pcpu | head -20`). Load versus how many CPUs, and whether the time is in `us`, `sy`, or `wa`. High `wa` is a disk problem that looks like CPU. High `us` with one or two processes is a runaway, not "the server is small".
2. Note the user on the hot process. On cPanel that user is the account. `tr '\0' ' ' < /proc/<pid>/cmdline` and `ls -l /proc/<pid>/cwd` to see the script. I'm looking for `php`/`lsphp`, `httpd`/`nginx`, `mysqld`, `exim`, `clamd`, or a `pkgacct`/`backup` process.
3. If it's PHP, which site. The cwd or the script path is under `/home/USER/public_html/...`. Common ones: `wp-cron.php` spawned over and over, `admin-ajax.php`, a plugin doing something in a loop, or a search. Then the vhost log, usually `/usr/local/apache/domlogs/USER` or the domain log under `/var/log/nginx/`. `tail` it and see if one URL or one IP is most of the lines. `xmlrpc.php` and `wp-login.php` floods show up here. I want the account name before I kill anything.
4. If CloudLinux is installed, `lveinfo` (for the last hour, sorted by CPU) so I can see which account is hitting its limit instead of guessing from `top`. That's the faster version of step 2 on those boxes.
5. If `mysqld` is the top process, `mysqladmin processlist` or `mysql -e "SHOW FULL PROCESSLIST\G"`. I'm looking for one query running for a long time, or many copies of the same query, and the database name, which maps back to an account. I don't restart MySQL to "clear it".
6. `exim -bpc`. A queue of tens of thousands means a site is spamming and CPU is the MTA, not WordPress. `exim -bp | head` shows which sender. That's a compromised account until proven otherwise, and it's more urgent than a slow plugin.
7. `ps aux | grep -E 'pkgacct|backup|clamd|maldet' | grep -v grep`. cPanel's own backup or a malware scan at 100% CPU is a bad time to start killing PHP. I'd confirm it's the scheduled job and leave it if the box is otherwise healthy, or pause that one job.
8. If I still don't have a process, `dmesg -T | tail` for something else going on, but by this point `top` has almost always already named it.

If one PHP process is clearly stuck at the top and I know the account and the script, I'll kill that pid so the other 39 sites recover, and then look at why that script ran. I still won't restart the whole server in this window.
