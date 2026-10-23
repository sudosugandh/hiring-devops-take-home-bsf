#!/bin/sh
# Installs WordPress + demo content. Safe to re-run.
set -e
cd /var/www/html

echo "[setup] waiting for wp-config.php ..."
i=0
until [ -f wp-config.php ]; do
  i=$((i+1)); [ $i -gt 90 ] && { echo "[setup] wp-config.php never appeared"; exit 1; }
  sleep 2
done

echo "[setup] waiting for database ..."
i=0
until wp db check >/dev/null 2>&1; do
  i=$((i+1)); [ $i -gt 90 ] && { echo "[setup] database not reachable"; exit 1; }
  sleep 2
done

if ! wp core is-installed 2>/dev/null; then
  wp core install \
    --url="https://localhost:8443" \
    --title="BSF Demo Store" \
    --admin_user=admin \
    --admin_password=admin-pass-2026 \
    --admin_email=admin@example.com \
    --skip-email
fi

wp rewrite structure '/%postname%/' --hard >/dev/null
wp plugin activate bsf-shop
wp plugin is-installed redis-cache || wp plugin install redis-cache
wp plugin activate redis-cache
wp redis enable --force || true

# Init SQL adds this on a fresh volume. Re-apply it if the volume is older.
if ! wp db query "SHOW INDEX FROM wp_bsf_orders WHERE Key_name = 'customer_email_created'" | grep -q customer_email_created; then
  echo "[setup] indexing wp_bsf_orders (customer_email, created_at) ..."
  wp db query "ALTER TABLE wp_bsf_orders ADD INDEX customer_email_created (customer_email, created_at)"
fi

# Nothing in this stack reads a .env, and nginx would serve it as a static file.
rm -f .env wp-content/debug.log

echo "[setup] done. Open https://localhost:8443 (admin / admin-pass-2026)"
