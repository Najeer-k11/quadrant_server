#!/usr/bin/env bash
# Builds the current branch and deploys it, going back to the previous build if
# the new one does not become healthy. Run it on the server, as the user who
# cloned the repository, with no arguments.
set -euo pipefail

readonly SERVICE=quadrant-example
readonly INSTALL_DIR="${INSTALL_DIR:-/opt/quadrant-example}"
readonly PORT="${PORT:-5050}"

cd "$(dirname "${BASH_SOURCE[0]}")/.."

healthy() {
  for _ in $(seq 1 15); do
    if curl --silent --fail --max-time 2 "http://127.0.0.1:${PORT}/health" >/dev/null; then
      return 0
    fi
    sleep 1
  done
  return 1
}

echo "==> Fetching the latest code"
git pull --ff-only

echo "==> Building"
dart pub get --enforce-lockfile
mkdir -p build
dart compile exe lib/main.dart -o build/server

echo "==> Installing"
if [[ -f "${INSTALL_DIR}/server" ]]; then
  sudo cp -p "${INSTALL_DIR}/server" "${INSTALL_DIR}/server.previous"
fi
# Installed under another name first, then renamed, as a binary cannot be
# overwritten while it is running.
sudo install -m 755 build/server "${INSTALL_DIR}/server.new"
sudo mv -f "${INSTALL_DIR}/server.new" "${INSTALL_DIR}/server"

echo "==> Restarting"
sudo systemctl restart "${SERVICE}"

if healthy; then
  echo "==> Deployed $(git rev-parse --short HEAD)"
  exit 0
fi

echo "==> The new build did not become healthy" >&2
if [[ -f "${INSTALL_DIR}/server.previous" ]]; then
  echo "==> Going back to the previous build" >&2
  sudo cp -p "${INSTALL_DIR}/server.previous" "${INSTALL_DIR}/server.new"
  sudo mv -f "${INSTALL_DIR}/server.new" "${INSTALL_DIR}/server"
  sudo systemctl restart "${SERVICE}"
  healthy && echo "==> The previous build is running" >&2
fi
echo "==> See the logs with: journalctl -u ${SERVICE} -n 50" >&2
exit 1
