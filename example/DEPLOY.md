# Deploying to a VPS

This puts the example app on one server, running under systemd behind nginx with HTTPS. It takes about 20 minutes, and the steps are written for **Ubuntu 24.04 on x86-64**. Other Debian-based systems are similar.

```
Internet ──HTTPS──> nginx (:443) ──HTTP──> app (127.0.0.1:5050)
```

**You need:**

- A VPS with at least 1 GB of memory, and a user who can `sudo`.
- A domain name. This guide uses `api.example.com`, so replace it everywhere.
- This repository on a Git host the server can reach. The commands use the main repository, so use your fork if you have changes.

Commands run on the server unless they say otherwise.

## 1. Point your domain at the server

At your DNS provider, add an `A` record for `api.example.com` with the server's IPv4 address, and an `AAAA` record if it has IPv6. Then check it from your own computer:

```bash
dig +short api.example.com
```

Wait until this shows the server's address, because step 7 needs it.

## 2. Update the server and open the firewall

Allow SSH **before** enabling the firewall, or you will lock yourself out.

```bash
sudo apt update && sudo apt upgrade -y
sudo ufw allow OpenSSH
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw enable
sudo ufw status
```

Port 5050 stays closed, because only nginx should reach the app.

On a server with 1 GB of memory, add swap so that compiling does not run out:

```bash
sudo fallocate -l 2G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
```

## 3. Install Dart, nginx and certbot

```bash
sudo apt install -y apt-transport-https curl git nginx certbot python3-certbot-nginx

curl -fsSL https://dl-ssl.google.com/linux/linux_signing_key.pub \
  | sudo gpg --dearmor -o /usr/share/keyrings/dart.gpg
echo 'deb [signed-by=/usr/share/keyrings/dart.gpg arch=amd64] https://storage.googleapis.com/download.dartlang.org/linux/debian stable main' \
  | sudo tee /etc/apt/sources.list.d/dart_stable.list
sudo apt update
sudo apt install -y dart

dart --version
```

## 4. Build the app

```bash
git clone https://github.com/Najeer-k11/quadrant_server.git ~/quadrant_server
cd ~/quadrant_server/example

dart pub get --enforce-lockfile
mkdir -p build
dart compile exe lib/main.dart -o build/server
```

The result is a single file with no runtime to install. In your own project, you would depend on the published package rather than `path: ..`.

Then create a user for the app to run as, and install the file:

```bash
sudo useradd --system --no-create-home --shell /usr/sbin/nologin quadrant
sudo install -d -m 755 /opt/quadrant-example
sudo install -m 755 build/server /opt/quadrant-example/server
```

## 5. Add the settings

```bash
sudo install -d -m 750 -g quadrant /etc/quadrant-example
sudo install -m 640 -g quadrant deploy/app.env.example /etc/quadrant-example/app.env

sudo sed -i "s/^ADMIN_TOKEN=.*/ADMIN_TOKEN=$(openssl rand -hex 32)/" /etc/quadrant-example/app.env
sudo sed -i "s/^USER_TOKEN=.*/USER_TOKEN=$(openssl rand -hex 32)/" /etc/quadrant-example/app.env

sudo cat /etc/quadrant-example/app.env
```

Keep a copy of the tokens in your password manager, because API clients need them.

## 6. Start the app

```bash
sudo cp deploy/quadrant-example.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now quadrant-example

systemctl status quadrant-example --no-pager
curl -i http://127.0.0.1:5050/health
```

You should see `active (running)` and a `200`. If not, see [Troubleshooting](#troubleshooting).

## 7. Add nginx and HTTPS

```bash
sudo cp deploy/nginx.conf /etc/nginx/sites-available/quadrant-example
sudo sed -i 's/api\.example\.com/api.yourdomain.com/' /etc/nginx/sites-available/quadrant-example
sudo ln -s /etc/nginx/sites-available/quadrant-example /etc/nginx/sites-enabled/
sudo rm -f /etc/nginx/sites-enabled/default

sudo nginx -t
sudo systemctl reload nginx
```

Then get a certificate. Certbot edits the nginx file to add HTTPS and a redirect from HTTP, and sets up renewal:

```bash
sudo certbot --nginx -d api.example.com
sudo certbot renew --dry-run
```

## 8. Check it from your own computer

```bash
export API=https://api.example.com
export TOKEN=your-admin-token

# Works: 200
curl -i $API/api/v1/info

# The token is required: 401, then 201
curl -i -X POST $API/api/v1/users -H 'Content-Type: application/json' -d '{"name":"Test"}'
curl -i -X POST $API/api/v1/users -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' -d '{"name":"Test"}'

# An upload, stored on the server: 201
curl -i -X POST $API/api/v1/files -H "Authorization: Bearer $TOKEN" -F 'file=@some-file.jpg'

# Private things are hidden: 404, 404
curl -I $API/health
curl -I $API/quadrant_docs

# The port is closed: this times out or is refused
curl -m 5 http://api.example.com:5050/health
```

For the WebSocket, connect a client to `wss://api.example.com/ws/chat/general`.

## Day-to-day

**Deploy a new version.** This pulls, builds, restarts, and goes back to the previous build if the new one does not become healthy:

```bash
~/quadrant_server/example/deploy/update.sh
```

**Read the logs:**

```bash
journalctl -u quadrant-example -f            # Follow
journalctl -u quadrant-example -n 100        # Latest
journalctl -u quadrant-example -p err        # Errors
```

**Stop or restart.** Requests in flight get up to 20 seconds to finish, and open WebSockets are told the server is going away:

```bash
sudo systemctl restart quadrant-example
```

**Change a setting.** Edit the file, then restart:

```bash
sudo nano /etc/quadrant-example/app.env
sudo systemctl restart quadrant-example
```

**Back up.** Copy `/var/lib/quadrant-example/uploads`, for example with `rsync` to another machine. Users are in memory in this example, so they are lost on every restart. Your own app should keep them in a database, and back that up too.

**Keep the server updated:** `sudo apt update && sudo apt upgrade -y`. Security updates install by themselves on Ubuntu, through `unattended-upgrades`, if it is enabled.

## What happens when things go wrong

| What happens | What you see |
|---|---|
| An isolate dies | It is replaced by a new one. Its open connections get no error, so nginx ends those requests after its 60-second timeout |
| An isolate keeps dying | After about 3 minutes the app exits, and systemd starts it afresh |
| The process crashes | systemd restarts it after 2 seconds |
| A setting is wrong | The app exits with code 78 and systemd does not retry. Fix it and restart |
| The server reboots | systemd starts the app again, as it is enabled |
| The disk fills up | Uploads answer `500`. Keep an eye on `df -h` |

Rate limit counts are in memory, so a restart resets them. That matters only if you need strict limits, such as on logins. To protect logins across restarts, keep attempts in your database.

## Troubleshooting

| Symptom | Likely cause and fix |
|---|---|
| `status` shows `exit-code` with `status=78` | A setting is wrong. `journalctl -u quadrant-example -n 20` names it |
| `Permission denied` running the binary | `sudo chmod 755 /opt/quadrant-example/server` |
| `Address already in use` | Something else has port 5050: `sudo ss -ltnp \| grep 5050` |
| `502 Bad Gateway` | The app is not running: `systemctl status quadrant-example` |
| `504 Gateway Timeout` | The request took over 60 seconds, or its isolate died. Check the logs |
| `413` from nginx, as an HTML page | Raise `client_max_body_size` in the nginx file, and `maxUploadBytes` in the app |
| Everyone shares one rate limit | `TRUSTED_PROXY_HOPS` is not `1` |
| WebSocket closes after about a minute | The `location /ws/` block is missing from the nginx file |
| certbot cannot verify the domain | DNS has not updated yet, or port 80 is closed: `sudo ufw status` |
| `dart compile` is killed | Out of memory. Add the swap from step 2 |

## Using Docker instead

Instead of steps 3 to 6, install Docker, then:

```bash
git clone https://github.com/Najeer-k11/quadrant_server.git ~/quadrant_server
cd ~/quadrant_server/example

cp deploy/app.env.example .env
chmod 600 .env
sed -i "s/^ADMIN_TOKEN=.*/ADMIN_TOKEN=$(openssl rand -hex 32)/" .env
sed -i "s/^USER_TOKEN=.*/USER_TOKEN=$(openssl rand -hex 32)/" .env

docker compose up --build -d
docker compose ps
docker compose logs -f
```

Step 7 is the same, as Compose publishes the port on `127.0.0.1:5050`. To update, run `git pull && docker compose up --build -d`.
