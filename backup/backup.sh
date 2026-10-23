#!/bin/sh
# Dump the wordpress database and upload it to s3://$S3_BUCKET/$S3_PREFIX/
# If mariadb-dump fails, the job fails. Don't ship a gzip of an empty stdout.
set -eu
set -o pipefail

: "${DB_HOST:?}"
: "${DB_USER:?}"
: "${DB_PASSWORD:?}"
: "${DB_NAME:?}"
: "${AWS_ACCESS_KEY_ID:?}"
: "${AWS_SECRET_ACCESS_KEY:?}"
: "${S3_ENDPOINT:?}"
: "${S3_BUCKET:?}"
: "${S3_PREFIX:?}"
: "${AWS_DEFAULT_REGION:=us-east-1}"

export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION
export AWS_S3_ADDRESSING_STYLE=path

STAMP=$(date +%Y%m%d-%H%M%S)
FILE=/tmp/wordpress-$STAMP.sql.gz
CNF=/tmp/backup-client.cnf

cleanup() {
  rm -f "$CNF" "$FILE"
}
trap cleanup EXIT

umask 077
cat > "$CNF" <<EOF
[client]
host=$DB_HOST
user=$DB_USER
password=$DB_PASSWORD
EOF

echo "[backup] dumping ${DB_NAME} ..."
mariadb-dump \
  --defaults-extra-file="$CNF" \
  --single-transaction \
  --quick \
  --default-character-set=utf8mb4 \
  "$DB_NAME" | gzip > "$FILE"

gzip -t "$FILE"
bytes=$(wc -c < "$FILE")
echo "[backup] dump is ${bytes} bytes, uploading ..."

aws --endpoint-url "$S3_ENDPOINT" s3 cp \
  "$FILE" "s3://${S3_BUCKET}/${S3_PREFIX}/$(basename "$FILE")"

echo "[backup] done: s3://${S3_BUCKET}/${S3_PREFIX}/$(basename "$FILE")"
