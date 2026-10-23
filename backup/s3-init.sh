#!/bin/sh
# Create the bucket and a user that can only upload under site-x/.
# mc alias set does not connect, so admin info is the actual wait.
set -eu

: "${MINIO_ROOT_USER:?}"
: "${MINIO_ROOT_PASSWORD:?}"
: "${BACKUP_ACCESS_KEY:?}"
: "${BACKUP_SECRET_KEY:?}"

export MC_DISABLE_PAGER=1

# alias set probes the server, so it has to be inside the retry.
echo "[s3-init] waiting for minio ..."
i=0
until mc alias set local http://s3:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null 2>&1 \
  && mc admin info local >/dev/null 2>&1
do
  i=$((i+1))
  if [ "$i" -gt 40 ]; then
    echo "[s3-init] minio never came up" >&2
    mc alias set local http://s3:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" || true
    exit 1
  fi
  sleep 2
done

mc mb -p local/bsf-backups >/dev/null 2>&1 || true

# create overwrites an existing policy, so a second boot stays in sync
mc admin policy create local backup-upload /policy.json

if ! mc admin user info local "$BACKUP_ACCESS_KEY" >/dev/null 2>&1; then
  mc admin user add local "$BACKUP_ACCESS_KEY" "$BACKUP_SECRET_KEY"
fi

mc admin policy attach local backup-upload --user "$BACKUP_ACCESS_KEY" >/dev/null 2>&1 || true

info=$(mc admin user info local "$BACKUP_ACCESS_KEY")
printf '%s\n' "$info"
case "$info" in
  *backup-upload*) ;;
  *)
    echo "[s3-init] ${BACKUP_ACCESS_KEY} does not have backup-upload" >&2
    exit 1
    ;;
esac

echo "[s3-init] ${BACKUP_ACCESS_KEY} can upload to bsf-backups/site-x/"
