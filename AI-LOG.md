# How I used AI
## Tools used

- [Claude](https://claude.ai)

## How I used it

**A dump that exits 0 is not a backup.**  
`backup.sh` was `mariadb-dump | gzip` with `set -e`, then an upload. In `/bin/sh`, `set -e` does not fail the script when the first stage of a pipeline fails. The gzip of an empty stdout still succeeds, `aws s3 cp` returns 0, and the log says done. I was already dropping `--all-databases` and the root account. I asked Claude which line hides the failure. It said `pipefail`. I checked that Alpine's `/bin/sh` has it, then I shipped that.

**What the database user actually needs.**  
Claude suggested dumping as root, or `GRANT ALL` / `RELOAD ON *.*`, so the dump could not fail on a missing privilege. `--single-transaction` on InnoDB does not need `RELOAD`. The account in `db/init/20-backup-user.sql` is `SELECT`, `SHOW VIEW`, `TRIGGER`, and `LOCK TABLES` on `wordpress` only. It cannot write, and it cannot see the other databases.

**The upload role.**  
New objects under `s3://bsf-backups/site-x/` only. A large `aws s3 cp` uses multipart, so the policy has `PutObject`, `AbortMultipartUpload`, and `ListMultipartUploadParts`. I had Claude read it for anything wider.

## Key prompts

1. Backup pipeline

   ```text
   backup.sh is `mariadb-dump | gzip` with set -e, then aws s3 cp.
   Which part still exits 0 when the dump fails?
   ```

2. Database grant

   ```text
   InnoDB dump with --single-transaction. What is the minimum grant
   on the wordpress database? Do not offer root or RELOAD on *.*.
   ```

3. Upload policy

   ```text
   Upload only under s3://bsf-backups/site-x/. Multipart is in scope.
   List and delete are not. Did I grant either?
   ```

## When the AI was wrong or risky

Two suggestions would have made the job look fine and made it worse.

- Add `s3:ListBucket` and `s3:DeleteObject` so the job can see old backups and delete them. The uploader could then read every backup name and wipe them. Retention is a bucket lifecycle rule, not a privilege on this job.
- Dump as root, or grant `RELOAD` on `*.*`. That is a global privilege so the client does not error. `--single-transaction` does not need it. The backup user stays read-only on `wordpress`.

I ran the job with the limited S3 user. The upload succeeded. List and delete both came back access denied.

## What I would not let an AI do unchecked

- Run a dump or a restore it wrote against the database. Exit code 0 is not a backup.
- Widen an IAM policy, or a database grant, because the client complained.
- Delete a volume or flush a cache to clear an error.
