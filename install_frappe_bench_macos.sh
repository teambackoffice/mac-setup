#!/bin/bash

# =============================================================================
# Frappe Bench Automatic Installation Script for macOS
# Non-interactive version - no manual steps required
# Idempotent: safe to re-run multiple times
#
# Lines marked "FIX:" are changes from the previous version.
# =============================================================================

set -euo pipefail

# --- Colour helpers -----------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
err()  { echo -e "${RED}✗ $*${NC}" >&2; }
ok()   { echo -e "${GREEN}✓ $*${NC}"; }
skip() { echo -e "${CYAN}⊙ $* (already done, skipping)${NC}"; }
info() { echo -e "\n${YELLOW}>>> $*${NC}\n"; }

# =============================================================================
# CONFIGURATION — edit these before running, or pass them as env vars
# =============================================================================
MYSQL_ROOT_PASSWORD="${MYSQL_ROOT_PASSWORD:-}"   # Set via env, or generated on a fresh MariaDB
FRAPPE_BRANCH="${FRAPPE_BRANCH:-version-15}"
PYTHON_VERSION="${PYTHON_VERSION:-3.10.15}"      # Full x.y.z version (built by pyenv)
BENCH_DIR="${BENCH_DIR:-$HOME/frappe-bench}"
# FIX: node@18 is disabled in Homebrew, so `brew install node@18` now fails.
#      Frappe v15 needs Node 18+, so default to node@22.
NODE_VERSION="${NODE_VERSION:-node@22}"
# NOTE: mariadb@10.6 is deprecated in Homebrew — it still installs, with a warning.
MARIADB_VERSION="${MARIADB_VERSION:-mariadb@10.6}"
#
# For a version-16 bench, Frappe needs Python 3.14, Node 24 and MariaDB 11.8, e.g.:
#   FRAPPE_BRANCH=version-16 PYTHON_VERSION=3.14.x NODE_VERSION=node@24 \
#   MARIADB_VERSION=mariadb@11.8 bash install_frappe_bench_macos.sh
# =============================================================================

# --- Runtime state + cleanup --------------------------------------------------
CLT_PLACEHOLDER="/tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress"
CLT_PLACEHOLDER_CREATED=false
SUDO_KEEPALIVE_PID=""
BREW_BIN=""
KEG_PATHS=""

cleanup() {
    if [[ "$CLT_PLACEHOLDER_CREATED" == true ]]; then rm -f "$CLT_PLACEHOLDER"; fi
    if [[ -n "$SUDO_KEEPALIVE_PID" ]]; then kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true; fi
}
trap cleanup EXIT

echo ""
echo "======================================"
echo " Frappe Bench Auto-Installer (macOS) "
echo "======================================"
echo ""

# macOS guard
[[ "$OSTYPE" == darwin* ]] || { err "This script is for macOS only."; exit 1; }

# FIX: refuse to run as root. Homebrew won't install as root, and pyenv/bench would
#      end up owned by root. The script asks for sudo itself only when it needs it.
[[ $EUID -ne 0 ]] || { err "Run this as your normal user, not with sudo."; exit 1; }

command_exists() { command -v "$1" >/dev/null 2>&1; }

# Add a line permanently to ~/.zshrc (idempotent)
add_to_zshrc() {
    local marker="$1" line="$2"
    grep -qF "$marker" ~/.zshrc 2>/dev/null || printf '\n%s\n' "$line" >> ~/.zshrc
}

# FIX: Homebrew's NONINTERACTIVE installer and `softwareupdate -i` both need sudo.
#      The installer never prompts in that mode — without a cached sudo session it
#      just aborts with "Need sudo access on macOS". Ask once, keep it alive.
ensure_sudo() {
    if [[ -n "$SUDO_KEEPALIVE_PID" ]]; then return 0; fi
    echo "  Administrator rights needed for this step — enter your Mac login password if asked."
    sudo -v || { err "Couldn't get sudo access (your macOS user must be an Administrator)."; exit 1; }
    ( while true; do sudo -n true 2>/dev/null; sleep 50; kill -0 "$$" 2>/dev/null || exit 0; done ) &
    SUDO_KEEPALIVE_PID=$!
}

# FIX: `xcode-select -p` alone can succeed even when the CLT files are gone.
clt_installed() {
    local dir
    dir="$(xcode-select -p 2>/dev/null)" || return 1
    [[ -x "$dir/usr/bin/git" ]]
}

# FIX: find brew by its real location (Apple Silicon or Intel), not only via PATH —
#      `bash script.sh` doesn't read ~/.zshrc, so brew may not be on PATH on a re-run.
find_brew() {
    if   [[ -x /opt/homebrew/bin/brew ]]; then echo /opt/homebrew/bin/brew
    elif [[ -x /usr/local/bin/brew ]];    then echo /usr/local/bin/brew
    elif command_exists brew;             then command -v brew
    fi
}

# Re-apply tool paths in THIS shell.
# FIX: brew's init is eval'd with `set -u` relaxed; for pyenv only the PATH part is
#      needed (python/bench are called by full path below); keg-only bins (node,
#      mariadb) are re-added last so they stay ahead of brew's own bin dir.
reload_env() {
    set +u
    eval "$("$BREW_BIN" shellenv)"
    set -u
    export PYENV_ROOT="$HOME/.pyenv"
    export PATH="$PYENV_ROOT/shims:$PYENV_ROOT/bin:$PATH"
    [[ -z "$KEG_PATHS" ]] || export PATH="$KEG_PATHS:$PATH"
}

# FIX: single awk instead of `awk | grep -q`. Under `pipefail`, grep -q exiting early
#      can SIGPIPE the left side and make the check fail even when the service runs.
service_started() {
    brew services list 2>/dev/null | awk -v s="$1" '$1 == s && $2 == "started" { f = 1 } END { exit !f }'
}

# ---------------------------------------------------------------------------
# STEP 1 — Xcode Command Line Tools
# ---------------------------------------------------------------------------
# NOTE: This is the small "Command Line Tools" package, NOT the full Xcode.app.
# It is a genuine, non-skippable requirement: it's where Homebrew and pyenv
# (which compiles Python from source in Step 9) get their C compiler from.
#
# FIX vs. previous version: the pattern-matching lines below used to be
#   [[ -z "$PROD" ]] && PROD=$(... | grep ... | ...)
# Under `set -euo pipefail`, if the grep found no match, that assignment
# (being the last command in the && list) was NOT exempt from `set -e`, so
# the whole script would silently die right there — before ever trying the
# other patterns or the GUI fallback. Fixed below with `|| true` guards, plus
# the GUI fallback now waits for you instead of requiring a manual re-run.
# ---------------------------------------------------------------------------
info "Step 1: Xcode Command Line Tools"
if clt_installed; then
    skip "Xcode CLT"
else
    touch "$CLT_PLACEHOLDER"
    CLT_PLACEHOLDER_CREATED=true
    SU_LIST=$(softwareupdate -l 2>/dev/null || true)

    PROD=""

    # Pattern 1 — current format: "* Label: Command Line Tools for Xcode-16.x"
    [[ -z "$PROD" ]] && PROD=$(echo "$SU_LIST" \
        | grep -E "\*.*Label:.*Command Line Tools" \
        | sed -E 's/.*Label: *//' \
        | sort -V \
        | tail -1 \
        | tr -d '\n') || true

    # Pattern 2 — older format (pre-Ventura): "* Command Line Tools for Xcode ..."
    [[ -z "$PROD" ]] && PROD=$(echo "$SU_LIST" \
        | grep -E "\*.*Command Line Tools" \
        | sed -E 's/^[[:space:]]*\*[[:space:]]*//' \
        | sort -V \
        | tail -1 \
        | tr -d '\n') || true

    # Pattern 3 — broadest fallback: anything containing "CommandLineTools" or "CLTools"
    [[ -z "$PROD" ]] && PROD=$(echo "$SU_LIST" \
        | grep -iE "(CommandLineTools|CLTools|Command.Line.Tools)" \
        | grep "\*" \
        | sed -E 's/.*Label: *//' \
        | sed -E 's/^[[:space:]]*\*[[:space:]]*//' \
        | sort -V \
        | tail -1 \
        | tr -d '\n') || true

    if [[ -n "$PROD" ]]; then
        echo "  Found package: $PROD"
        # FIX: `softwareupdate -i` must run as root, and the placeholder file has to
        #      stay in place until the install finishes (it used to be deleted first).
        ensure_sudo
        sudo softwareupdate -i "$PROD" --verbose
        sudo xcode-select --switch /Library/Developer/CommandLineTools || true
    else
        rm -f "$CLT_PLACEHOLDER"
        echo ""
        echo -e "${YELLOW}  ⚠ Could not auto-detect the CLT package name via softwareupdate.${NC}"
        echo "  Raw softwareupdate output (copy this if reporting an issue):"
        echo "---"
        echo "$SU_LIST"
        echo "---"
        echo ""
        echo "  Falling back to the standard installer — a dialog will pop up, click 'Install'."
        echo "  This script will WAIT for it to finish, so you don't need to re-run anything."
        xcode-select --install 2>/dev/null || true

        echo -n "  Waiting for install to complete (checks every 10s, up to ~30 min)"
        for _ in $(seq 1 180); do
            if clt_installed; then break; fi
            echo -n "."
            sleep 10
        done
        echo ""
    fi
    rm -f "$CLT_PLACEHOLDER"

    clt_installed || { err "Xcode CLT not detected. Finish the install, then re-run this script."; exit 1; }
    ok "Xcode CLT installed"
fi

# ---------------------------------------------------------------------------
# STEP 2 — Homebrew
# ---------------------------------------------------------------------------
info "Step 2: Homebrew"
BREW_BIN="$(find_brew)"
if [[ -n "$BREW_BIN" ]]; then
    skip "Homebrew"
else
    ensure_sudo
    NONINTERACTIVE=1 /bin/bash -c \
        "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    BREW_BIN="$(find_brew)"
    [[ -n "$BREW_BIN" ]] || { err "Homebrew install finished but brew wasn't found."; exit 1; }
    ok "Homebrew installed"
fi

reload_env
# FIX: everything below uses the real brew prefix (/opt/homebrew on Apple Silicon,
#      /usr/local on Intel). It was hard-coded to /opt/homebrew before, so on an
#      Intel Mac writing my.cnf in Step 6 failed and killed the script.
BREW_PREFIX="$(brew --prefix)"
add_to_zshrc "brew shellenv" "eval \"\$($BREW_BIN shellenv)\""

# ---------------------------------------------------------------------------
# STEP 3 — PATH configuration in ~/.zshrc
# ---------------------------------------------------------------------------
# FIX: removed `export PATH="/opt/homebrew/lib:$PATH"` — lib/ holds libraries, not
#      commands. Added the mariadb keg bin, which was never put on PATH.
info "Step 3: ~/.zshrc PATH configuration"
add_to_zshrc "opt/$NODE_VERSION/bin"    "export PATH=\"$BREW_PREFIX/opt/$NODE_VERSION/bin:\$PATH\""
add_to_zshrc "opt/$MARIADB_VERSION/bin" "export PATH=\"$BREW_PREFIX/opt/$MARIADB_VERSION/bin:\$PATH\""
ok "~/.zshrc paths ensured"

# ---------------------------------------------------------------------------
# STEP 4 — Homebrew packages
# ---------------------------------------------------------------------------
# FIX: dropped python@3.10. pyenv builds the Python that bench uses (Step 9);
#      brew's copy only got force-linked over brew's python3/pip3 and made `pip3`
#      ambiguous. The libraries pyenv needs to build Python are listed instead.
info "Step 4: Installing Homebrew packages"
PACKAGES=("git" "redis" "$MARIADB_VERSION" "$NODE_VERSION" "yarn" "pyenv"
          "openssl@3" "readline" "sqlite" "xz")
for pkg in "${PACKAGES[@]}"; do
    if brew list "$pkg" &>/dev/null; then
        skip "$pkg"
    else
        echo "  Installing $pkg..."
        brew install "$pkg"
        ok "$pkg"
    fi
done

# ---------------------------------------------------------------------------
# STEP 5 — Force-link keg-only packages
# ---------------------------------------------------------------------------
info "Step 5: Linking keg-only packages"
brew link --force --overwrite "$MARIADB_VERSION" 2>/dev/null || true
brew link --force --overwrite "$NODE_VERSION"    2>/dev/null || true
# FIX: don't rely on the (silenced) links alone — put the keg bins on PATH for this
#      run too, otherwise a failed link leaves `mysql`/`node` missing later on.
KEG_PATHS="$BREW_PREFIX/opt/$MARIADB_VERSION/bin:$BREW_PREFIX/opt/$NODE_VERSION/bin"
export PATH="$KEG_PATHS:$PATH"
ok "Packages linked"

# ---------------------------------------------------------------------------
# STEP 6 — MariaDB configuration file
# ---------------------------------------------------------------------------
info "Step 6: MariaDB my.cnf"
MYCNF="$BREW_PREFIX/etc/my.cnf"
MYCNF_CHANGED=false
if grep -q "utf8mb4_unicode_ci" "$MYCNF" 2>/dev/null; then
    skip "my.cnf"
else
    mkdir -p "$(dirname "$MYCNF")"
    if [[ -f "$MYCNF" ]]; then cp "$MYCNF" "$MYCNF.bak.$(date +%Y%m%d%H%M%S)"; fi
    cat > "$MYCNF" << 'EOF'
[mysqld]
character-set-client-handshake = FALSE
character-set-server = utf8mb4
collation-server = utf8mb4_unicode_ci
bind-address = 127.0.0.1

[mysql]
default-character-set = utf8mb4
EOF
    MYCNF_CHANGED=true
    ok "my.cnf written"
fi

# ---------------------------------------------------------------------------
# STEP 7 — Start MariaDB (only start once; don't bounce if healthy)
# ---------------------------------------------------------------------------
info "Step 7: MariaDB service"
if service_started "$MARIADB_VERSION"; then
    # FIX: if my.cnf was just written while MariaDB was already running, the utf8mb4
    #      settings were never applied. Restart only in that case.
    if [[ "$MYCNF_CHANGED" == true ]]; then
        brew services restart "$MARIADB_VERSION"
        ok "MariaDB restarted to apply the new my.cnf"
    else
        skip "MariaDB already running"
    fi
else
    brew services start "$MARIADB_VERSION"
    ok "MariaDB started"
fi

# Newer MariaDB ships only mariadb-* names; 10.6 has both.
MYSQL_BIN="$(command -v mariadb || command -v mysql || true)"
MYSQLADMIN_BIN="$(command -v mariadb-admin || command -v mysqladmin || true)"
if [[ -z "$MYSQL_BIN" || -z "$MYSQLADMIN_BIN" ]]; then
    err "MariaDB client tools not found (looked in $BREW_PREFIX/opt/$MARIADB_VERSION/bin)."
    exit 1
fi

# FIX: the old wait loop's second attempt used `-p""`, which bash turns into a bare
#      `-p` — mysql then waits for a password on the terminal (hidden by &>/dev/null)
#      and the script hangs. `ping` only checks the server is up (it succeeds even
#      when login is denied), and the loop now fails loudly if MariaDB never starts.
echo "  Waiting for MariaDB to accept connections..."
DB_UP=false
for _ in $(seq 1 30); do
    if "$MYSQLADMIN_BIN" --no-defaults --connect-timeout=2 ping &>/dev/null; then
        DB_UP=true
        break
    fi
    sleep 1
done
if [[ "$DB_UP" != true ]]; then
    err "MariaDB didn't come up within 30s. Check: brew services info $MARIADB_VERSION"
    err "and the *.err log in $BREW_PREFIX/var/mysql/"
    exit 1
fi
ok "MariaDB is accepting connections"

# ---------------------------------------------------------------------------
# STEP 8 — MariaDB root password  (NON-INTERACTIVE)
# ---------------------------------------------------------------------------
info "Step 8: MariaDB root password"

# FIX: every test uses --no-defaults so the client ignores ~/.my.cnf. Before, the
#      saved password in ~/.my.cnf was picked up automatically, so the "no password"
#      test passed on every re-run and the script reset root to a NEW random password
#      each time. The password goes via MYSQL_PWD so an empty one can't trigger a prompt.
mysql_test() {   # $1 = password ("" = try with no password)
    if [[ -n "${1:-}" ]]; then
        MYSQL_PWD="$1" "$MYSQL_BIN" --no-defaults -u root --connect-timeout=3 -e "SELECT 1" &>/dev/null
    else
        "$MYSQL_BIN" --no-defaults -u root --connect-timeout=3 -e "SELECT 1" &>/dev/null
    fi
}

read_stored_password() {
    [[ -f "$HOME/.my.cnf" ]] || return 0
    awk '/^[ \t]*password[ \t]*=/ {
            sub(/^[^=]*=[ \t]*/, ""); sub(/[ \t]+$/, "")
            if ($0 ~ /^".*"$/) $0 = substr($0, 2, length($0) - 2)
            print; exit
         }' "$HOME/.my.cnf"
}

has_unsafe_chars() {   # quotes/backslashes would break the SQL and ~/.my.cnf
    case "$1" in *\'*|*\"*|*\\*) return 0 ;; *) return 1 ;; esac
}

# Run SQL from stdin as a root login that needs no password
root_nopw_sql() {
    if [[ "$1" == "sudo" ]]; then
        sudo -n "$MYSQL_BIN" --no-defaults -u root
    else
        "$MYSQL_BIN" --no-defaults -u root
    fi
}

FOUND_PASSWORD=""
STORED_PW="$(read_stored_password)"

if [[ -n "$MYSQL_ROOT_PASSWORD" ]] && mysql_test "$MYSQL_ROOT_PASSWORD"; then
    FOUND_PASSWORD="$MYSQL_ROOT_PASSWORD"
    skip "MariaDB root password (env var MYSQL_ROOT_PASSWORD verified)"
elif [[ -n "$STORED_PW" ]] && mysql_test "$STORED_PW"; then
    FOUND_PASSWORD="$STORED_PW"
    skip "MariaDB root password (read from ~/.my.cnf)"
else
    # FIX: a fresh Homebrew MariaDB (10.4+) has no root password, but root logs in via
    #      unix_socket — only the macOS *root* user gets in, so plain `mysql -u root`
    #      is refused. The old script took that as "root already has a password" and
    #      asked you for a password that never existed. Try both ways.
    ROOT_NOPW_MODE=""
    if mysql_test ""; then
        ROOT_NOPW_MODE="direct"
    else
        ensure_sudo
        if sudo -n "$MYSQL_BIN" --no-defaults -u root -e "SELECT 1" &>/dev/null; then
            ROOT_NOPW_MODE="sudo"
        fi
    fi

    if [[ -n "$ROOT_NOPW_MODE" ]]; then
        echo "  Root can log in without a password (fresh install) — setting one now."
        if [[ -z "$MYSQL_ROOT_PASSWORD" ]]; then
            # FIX: the old `tr ... </dev/urandom | head -c 20` always dies with SIGPIPE;
            #      under `set -e` + `pipefail` that silently ended the script right here.
            #      Also, '#' in the old character set starts a comment in ~/.my.cnf,
            #      so the saved password could be cut short. Hex avoids both.
            MYSQL_ROOT_PASSWORD="$(openssl rand -hex 16)"
            echo -e "${YELLOW}  No password supplied. A secure password has been generated.${NC}"
        elif has_unsafe_chars "$MYSQL_ROOT_PASSWORD"; then
            err "MYSQL_ROOT_PASSWORD can't contain quotes or backslashes. Pick another and re-run."
            exit 1
        fi
        root_nopw_sql "$ROOT_NOPW_MODE" << SQL
ALTER USER 'root'@'localhost' IDENTIFIED VIA mysql_native_password USING PASSWORD('${MYSQL_ROOT_PASSWORD}');
FLUSH PRIVILEGES;
SQL
        mysql_test "$MYSQL_ROOT_PASSWORD" || { err "Root password was set but logging in with it failed."; exit 1; }
        FOUND_PASSWORD="$MYSQL_ROOT_PASSWORD"
        ok "MariaDB root password set"
    else
        # Root has a password we don't know — ask once (only interactive fallback)
        echo ""
        echo -e "${YELLOW}  MariaDB root already has a password and it was not found automatically.${NC}"
        echo "  You can avoid this prompt next time by running:"
        echo "    MYSQL_ROOT_PASSWORD='yourpassword' bash $0"
        echo ""
        read -rsp "  Enter existing MariaDB root password: " MYSQL_ROOT_PASSWORD
        echo ""
        if mysql_test "$MYSQL_ROOT_PASSWORD"; then
            FOUND_PASSWORD="$MYSQL_ROOT_PASSWORD"
            ok "Password verified"
        else
            err "Incorrect password. Re-run with: MYSQL_ROOT_PASSWORD='...' bash $0"
            exit 1
        fi
    fi
fi

# Persist to ~/.my.cnf so this script finds it silently next time.
# FIX: value is quoted (so '#' etc. can't truncate it) and saved whenever it changed,
#      including after the prompt, so the prompt really is a one-time thing.
if [[ "$FOUND_PASSWORD" != "$STORED_PW" ]]; then
    if has_unsafe_chars "$FOUND_PASSWORD"; then
        echo -e "${YELLOW}  Not saving to ~/.my.cnf (password contains quotes/backslashes).${NC}"
    else
        if [[ -f "$HOME/.my.cnf" ]]; then cp -p "$HOME/.my.cnf" "$HOME/.my.cnf.bak"; fi
        ( umask 077; printf '[client]\nuser=root\npassword="%s"\n' "$FOUND_PASSWORD" > "$HOME/.my.cnf" )
        chmod 600 "$HOME/.my.cnf"
        ok "Saved to ~/.my.cnf"
    fi
fi

echo ""
echo -e "${GREEN}  ✓ MariaDB root password is set.${NC}"
echo "    Save this for 'bench new-site': ${FOUND_PASSWORD}"
echo ""

# Export so bench-init can use it if needed
export MYSQL_ROOT_PASSWORD="$FOUND_PASSWORD"

# ---------------------------------------------------------------------------
# STEP 9 — pyenv + Python
# ---------------------------------------------------------------------------
info "Step 9: pyenv + Python $PYTHON_VERSION"

add_to_zshrc "PYENV_ROOT" \
'export PYENV_ROOT="$HOME/.pyenv"
export PATH="$PYENV_ROOT/bin:$PATH"
eval "$(pyenv init --path)"
eval "$(pyenv init -)"'

reload_env

# FIX: exact check on the install dir instead of `pyenv versions | grep -q` (pipefail-safe,
#      and doesn't match e.g. 3.10.150 when you asked for 3.10.15).
PY_PREFIX="$(pyenv root)/versions/$PYTHON_VERSION"
if [[ -x "$PY_PREFIX/bin/python" ]]; then
    skip "Python $PYTHON_VERSION"
else
    echo "  Building Python $PYTHON_VERSION (this takes a few minutes)..."
    pyenv install "$PYTHON_VERSION"
    ok "Python $PYTHON_VERSION installed"
fi

pyenv global "$PYTHON_VERSION"
reload_env
PY="$PY_PREFIX/bin/python"
echo "  Active Python: $("$PY" --version)"

# ---------------------------------------------------------------------------
# STEP 10 — Redis
# ---------------------------------------------------------------------------
info "Step 10: Redis"
if service_started redis; then
    skip "Redis"
else
    brew services start redis
    ok "Redis started"
fi

# ---------------------------------------------------------------------------
# STEP 11 — frappe-bench pip package
# ---------------------------------------------------------------------------
# FIX: pip runs through the pyenv Python explicitly. Bare `pip3` could resolve to
#      Homebrew's Python (-> "externally-managed-environment" error), and
#      --force-reinstall rebuilt bench AND all its dependencies on every run.
info "Step 11: frappe-bench pip package"
"$PY" -m pip install --upgrade pip -q
"$PY" -m pip install --upgrade frappe-bench -q
pyenv rehash
BENCH="$PY_PREFIX/bin/bench"
[[ -x "$BENCH" ]] || { err "bench not found at $BENCH after install"; exit 1; }
ok "bench $("$BENCH" --version)"

# ---------------------------------------------------------------------------
# STEP 12 — bench init
# ---------------------------------------------------------------------------
info "Step 12: bench init ($FRAPPE_BRANCH)"
if [[ -d "$BENCH_DIR/apps/frappe" && -f "$BENCH_DIR/sites/apps.txt" && -d "$BENCH_DIR/env" ]]; then
    skip "bench init ($BENCH_DIR is already a bench)"
elif [[ -e "$BENCH_DIR" ]]; then
    # FIX: any existing directory used to count as "done", so a half-finished
    #      bench init was skipped forever and you were left with a broken bench.
    err "$BENCH_DIR exists but isn't a complete bench (probably an earlier 'bench init' failed)."
    echo "  Move it aside and re-run:  mv \"$BENCH_DIR\" \"$BENCH_DIR.broken\""
    exit 1
else
    echo "  Python path : $PY"
    echo "  Bench dir   : $BENCH_DIR"
    echo "  Branch      : $FRAPPE_BRANCH"
    echo "  Node        : $(node --version)"
    echo ""
    echo "  Downloading Frappe and dependencies (may take several minutes)..."
    cd ~
    "$BENCH" init "$BENCH_DIR" \
        --frappe-branch "$FRAPPE_BRANCH" \
        --python "$PY" \
        || { err "bench init failed. Check errors above."; exit 1; }
    ok "bench init complete"
fi
cd "$BENCH_DIR"

# ---------------------------------------------------------------------------
# DONE
# ---------------------------------------------------------------------------
echo ""
echo "======================================"
echo -e "${GREEN} Bench setup complete! ${NC}"
echo "======================================"
echo ""
echo "  Bench location : $BENCH_DIR"
echo "  Python         : $("$PY" --version)"
echo "  Bench version  : $("$BENCH" --version)"
echo "  MariaDB root pw: $FOUND_PASSWORD"
echo "  (also stored in ~/.my.cnf)"
echo ""
echo "  Site creation is a manual step from here — run 'bench new-site' yourself"
echo "  once you're in $BENCH_DIR."
echo "======================================"
