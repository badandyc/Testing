#!/bin/bash
set -e

if [ "$EUID" -ne 0 ]; then
  echo "Run as root: sudo bash bdm_web_setup.sh"
  exit 1
fi

echo "=== Installing nginx ==="
apt update
apt install -y nginx

echo "=== Configuring nginx to bind only to AP (10.10.10.1) ==="

cat > /etc/nginx/sites-available/default <<EOF
server {
    listen 10.10.10.1:80;
    server_name _;

    root /var/www/html;
    index index.html;

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF

echo "=== Creating default BirdDog grid page ==="

cat > /var/www/html/index.html <<EOF
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<title>BirdDog Grid</title>
<style>
body { margin:0; background:#111; }
.grid {
  display:grid;
  grid-template-columns: 1fr 1fr;
  grid-template-rows: 1fr 1fr;
  height:100vh;
  gap:2px;
}
iframe {
  width:100%;
  height:100%;
  border:none;
}
</style>
</head>
<body>
<div class="grid">
  <iframe src="http://10.10.10.1:8889/cam01"></iframe>
  <iframe src="http://10.10.10.1:8889/cam02"></iframe>
  <iframe src="http://10.10.10.1:8889/cam03"></iframe>
  <iframe src="http://10.10.10.1:8889/cam04"></iframe>
</div>
</body>
</html>
EOF

echo "=== Enabling nginx ==="
systemctl enable nginx
systemctl restart nginx

echo "=== DONE ==="
echo "Dashboard available at: http://10.10.10.1"
