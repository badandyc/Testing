#!/bin/bash
set -e

if [ "$EUID" -ne 0 ]; then
  echo "Run as root: sudo bash bdm_web_setup.sh"
  exit 1
fi

echo "=== Installing nginx ==="
apt update
apt install -y nginx

echo "=== Writing nginx config ==="

cat > /etc/nginx/sites-available/default <<'EOF'
server {
    listen 80 default_server;
    listen [::]:80 default_server;

    server_name _;

    root /var/www/html;
    index index.html;

    location / {
        try_files $uri $uri/ =404;
    }
}
EOF

echo "=== Writing dashboard ==="

cat > /var/www/html/index.html <<'EOF'
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<title>BirdDog Dashboard</title>
<style>
body {
    background: #111;
    color: white;
    font-family: Arial, sans-serif;
    margin: 0;
    padding: 10px;
}
h1 {
    margin-top: 0;
}
button {
    padding: 6px 12px;
    margin-bottom: 10px;
}
.grid {
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(320px, 1fr));
    gap: 10px;
}
.tile {
    background: #222;
    padding: 8px;
    border-radius: 6px;
}
iframe {
    width: 100%;
    height: 240px;
    border: none;
}
</style>
</head>
<body>

<h1>BirdDog Live Grid</h1>
<button onclick="loadStreams()">Refresh</button>
<div class="grid" id="grid"></div>

<script>
async function loadStreams() {
    const grid = document.getElementById("grid");
    grid.innerHTML = "Loading...";

    try {
        const response = await fetch("http://10.10.10.1:9997/v3/paths/list");
        const data = await response.json();

        if (!data.items || data.items.length === 0) {
            grid.innerHTML = "No active streams.";
            return;
        }

        grid.innerHTML = "";

        data.items.forEach(item => {
            if (!item.ready) return;

            const tile = document.createElement("div");
            tile.className = "tile";

            const title = document.createElement("div");
            title.innerText = item.name;

            const frame = document.createElement("iframe");
            frame.src = `http://10.10.10.1:8889/${item.name}`;

            tile.appendChild(title);
            tile.appendChild(frame);
            grid.appendChild(tile);
        });

    } catch (err) {
        grid.innerHTML = "Error loading streams.";
    }
}

loadStreams();
</script>

</body>
</html>
EOF

echo "=== Restarting nginx ==="
nginx -t
systemctl restart nginx

echo "=== DONE ==="
echo "Open: http://10.10.10.1"
