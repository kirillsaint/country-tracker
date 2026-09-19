#!/usr/bin/env sh
# Генерирует /etc/nginx/cloudflare-ips.conf со списком set_real_ip_from для сетей Cloudflare,
# чтобы в логах и $remote_addr был IP клиента, а не Cloudflare. Запускать от root, можно по cron раз в неделю.
set -eu
OUT=/etc/nginx/cloudflare-ips.conf
TMP=$(mktemp)
{
  echo "# generated $(date -u +%FT%TZ) by update-cloudflare-ips.sh"
  curl -fsS https://www.cloudflare.com/ips-v4 | sed 's/^/set_real_ip_from /; s/$/;/'
  curl -fsS https://www.cloudflare.com/ips-v6 | sed 's/^/set_real_ip_from /; s/$/;/'
} > "$TMP"
mv "$TMP" "$OUT"
nginx -t && systemctl reload nginx
