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

echo "=== Creating dynamic BirdDog dashboard ==="

cat > /var/www/html/index.html <<'EOF'
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<title>BirdDog Grid</title>
<style>
body { margin:0; background:#111; color:white; font-family:sans-serif; }
#controls { padding:10px; background:#222; }
button { padding:6px 12px; }
.grid {
  display:grid;
  grid-template-columns: repeat(auto-fit, minmax(400px, 1fr));
  gap:2px;
}
iframe {
  width:100%;
  height:300px;
  border:none;
}
</style>
</head>
<body>

<div id="controls">
  <button onclick="loadStreams()">Refresh</button>
</div>

<div id="grid" class="grid"></div>

<script>
async function loadStreams() {
  const grid = document.getElementById("grid");
  grid.innerHTML = "";

  try {
    const response = await fetch("http://10.10.10.1:8888/v2/paths/list");
    const data = await response.json();

    if (!data.items || data.items.length === 0) {
      grid.innerHTML = "<p style='padding:10px'>No active streams</p>";
      return;
    }

    data.items.forEach(path => {
      if (path.name) {
        const iframe = document.createElement("iframe");
        iframe.src = `http://10.10.10.1:8889/${path.name}`;
        grid.appendChild(iframe);
      }
    });

  } catch (err) {
    grid.innerHTML = "<p style='padding:10px'>Error loading streams</p>";
  }
}

loadStreams();
</script>

</body>
</html>
EOF

echo "=== Enabling nginx ==="
systemctl enable nginx
systemctl restart nginx

echo "=== DONE ==="
echo "Dashboard available at: http://10.10.10.1"
