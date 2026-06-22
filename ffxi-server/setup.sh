#!/usr/bin/env bash
# =============================================================================
#  Ashen Era - bootstrap script
#
#  1. Clones LandSandBoat into ./server (skips if already there)
#  2. Installs the Souls modules into the checkout
#  3. Registers them in modules/init.txt
#  4. Applies the level-75 / punishing-death settings
#
#  After this, run:  cp .env.example .env  (edit it),  then  docker compose up -d
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER_DIR="$HERE/server"
LSB_REPO="https://github.com/LandSandBoat/server.git"

echo "==> Ashen Era setup"

# --- 1. Clone LandSandBoat -------------------------------------------------
if [ ! -d "$SERVER_DIR/.git" ]; then
    echo "==> Cloning LandSandBoat into ./server (this is large; ~minutes)"
    git clone "$LSB_REPO" "$SERVER_DIR"
else
    echo "==> ./server already exists, leaving it as-is"
fi

# --- 2. Install Souls modules ---------------------------------------------
echo "==> Installing Souls modules"
mkdir -p "$SERVER_DIR/modules/souls"
cp -R "$HERE/modules/souls/." "$SERVER_DIR/modules/souls/"

# --- 3. Register modules in init.txt --------------------------------------
echo "==> Registering modules in modules/init.txt"
INIT="$SERVER_DIR/modules/init.txt"
add_line() {
    grep -qxF "$1" "$INIT" || echo "$1" >> "$INIT"
}
add_line "souls/lua/souls_core.lua"
add_line "souls/lua/souls_earn.lua"
add_line "souls/lua/souls_death_penalty.lua"
add_line "souls/lua/souls_login.lua"
add_line "souls/commands/soul.lua"

# --- 4. Apply settings -----------------------------------------------------
echo "==> Applying level-75 + punishing-death settings"
MAIN="$SERVER_DIR/settings/default/main.lua"
MAP="$SERVER_DIR/settings/default/map.lua"

# Level-75 era cap.
sed -i -E 's/(MAX_LEVEL[[:space:]]*=[[:space:]]*)[0-9]+/\175/'        "$MAIN"
# Full EXP loss on death (the Souls bloodstain stacks on top of this).
sed -i -E 's/(EXP_RETAIN[[:space:]]*=[[:space:]]*)[0-9.]+/\10/'       "$MAP"

echo "==> Done."
echo
echo "Next steps:"
echo "  1. cp .env.example .env   # then edit SQL_PASSWORD"
echo "  2. See README.md -> 'Navmeshes' (needed for mob pathing)"
echo "  3. docker compose up -d --build"
echo "  4. Register an account, point a retail FFXI client at this host."
echo
echo "Review the rest of ffxi-server/settings/souls-settings.lua for optional tuning."
