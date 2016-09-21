#!/bin/bash

# Runtime
# --------
export TERM=${TERM:-xterm}
VERBOSE=${VERBOSE:-false}

# Environment
# ------------
ADMIN_EMAIL=${ADMIN_EMAIL:-"admin@${DB_NAME}.com"}
DB_NAME=${DB_NAME:-'wordpress'}
DB_PASS=${DB_PASS:-'root'}
DB_PREFIX=${DB_PREFIX:-'wp_'}
THEMES=${THEMES:-'twentysixteen'}
WP_DEBUG_DISPLAY=${WP_DEBUG_DISPLAY:-'true'}
WP_DEBUG_LOG=${WB_DEBUG_LOG:-'false'}
WP_DEBUG=${WP_DEBUG:-'false'}
[ "$SEARCH_REPLACE" ] && \
  BEFORE_URL=$(echo "$SEARCH_REPLACE" | cut -d ',' -f 1) && \
  AFTER_URL=$(echo "$SEARCH_REPLACE" | cut -d ',' -f 2) || \
  SEARCH_REPLACE=false


main() {

  generate_config_for wp-cli

  # Download WordPress
  # ------------------
  if [ ! -f /app/wp-settings.php ]; then
    h3 "Downloading wordpress"
    chown -R www-data:www-data /app /var/www/html
    WP core download |& loglevel
    STATUS ${PIPESTATUS[0]}
  fi

  # Wait for MySQL
  # --------------
  h2 "Waiting for MySQL to initialize..."
  while ! mysqladmin ping --host=db --password=$DB_PASS --silent; do
    sleep 1
  done

  h1 "Begin WordPress Configuration"

  h3 "Generating wp.config.php file"
  generate_config_for wordpress
  STATUS $?

  h2 "Checking database"
  check_database

  # .htaccess
  # ---------
  if [ ! -f /app/.htaccess ]; then
    h3 "Generating .htaccess file"
    if [[ "$MULTISITE" == 'true' ]]; then
      STATUS 1
      h3warn "Cannot generate .htaccess for multisite!"
    else
      WP rewrite flush --hard |& loglevel
      STATUS ${PIPESTATUS[0]}
    fi
  else
    h3 ".htaccess exists... SKIPPING"
    STATUS SKIP
  fi

  h3 "Adjusting filesystem permissions"
  groupadd -f docker && usermod -aG docker www-data
  find /app -type d -exec chmod 755 {} \;
  find /app -type f -exec chmod 644 {} \;
  mkdir -p /app/wp-content/uploads
  chmod -R 775 /app/wp-content/uploads && \
    chown -R :docker /app/wp-content/uploads
  STATUS $?

  h2 "Checking plugins"
  check_plugins

  # Make multisite
  # ---------------
  h2 "Checking for WordPress Multisite..."
  if [ "$MULTISITE" == "true" ]; then
    h3 "Multisite found. Enabling..."
    WP core multisite-convert |& loglevel
    STATUS ${PIPESTATUS[0]}
  else
    h3 "Multisite not found. Skipping..."
    STATUS SKIP
  fi

  # Operations to perform on first build
  # ------------------------------------
  if [ -d /app/wp-content/plugins/akismet ]; then
    first_build
  fi

  h1 "WordPress Configuration Complete!"

  rm -f /var/run/apache2/apache2.pid
  source /etc/apache2/envvars
  exec apache2 -D FOREGROUND

}


# General functions
# -----------------------
check_database() {
  WP core is-installed |& loglevel
  if [ ${PIPESTATUS[0]} == '1' ]; then
    h3 "Creating database $DB_NAME"
    WP db create |& loglevel
    STATUS ${PIPESTATUS[0]}

    # If an SQL file exists in /data => load it
    if [ "$(stat -t /data/*.sql >/dev/null 2>&1)" ]; then
      DATA_PATH=$(find /data/*.sql | head -n 1)
      h3 "Loading data backup from $DATA_PATH"

      WP db import "$DATA_PATH" |& loglevel
      STATUS ${PIPESTATUS[0]}

      # If SEARCH_REPLACE is set => Replace URLs
      if [ "$SEARCH_REPLACE" != false ]; then
        h3 "Replacing URLs"
        REPLACEMENTS=$(WP search-replace "$BEFORE_URL" "$AFTER_URL" \
          --skip-columns=guid | grep replacement) || \
          ERROR $((LINENO-2)) "Could not execute SEARCH_REPLACE on database"
        echo -ne "$REPLACEMENTS\n"
      fi
    else
      h3 "No database backup found. Initializing new database"
      WP core install |& loglevel
      STATUS ${PIPESTATUS[0]}
    fi
  else
    h3 "Database exists... SKIPPING"
    STATUS SKIP
  fi
}

check_plugins() {
  if [ "$PLUGINS" ]; then
    while IFS=',' read -ra plugin; do
      for i in "${!plugin[@]}"; do
        plugin_name=$(echo "${plugin[$i]}" | xargs)
        plugin_url=

        # If plugin matches a URL
        if [[ $plugin_name =~ ^https?://[www]?.+ ]]; then
          h3warn "$plugin_name"
          h3warn "Can't check if plugin is already installed using above format!"
          h3warn "Switch your compose file to '[plugin-slug]http://pluginurl.com/pluginfile.zip' for better checks"
          h3 "($((i+1))/${#plugin[@]}) '$plugin_name' not found. Installing"
          WP plugin install --activate "$plugin_name" --quiet
          STATUS $?
          continue
        fi

        # If plugin matches a URL in new URL format
        if [[ $plugin_name =~ ^\[.+\]https?://[www]?.+ ]]; then
          plugin_url=${plugin_name##\[*\]}
          plugin_name="$(echo $plugin_name | grep -oP '\[\K(.+)(?=\])')"
        fi

        plugin_url=${plugin_url:-$plugin_name}

        WP plugin is-installed "$plugin_name"
        if [ $? -eq 0 ]; then
          h3 "($((i+1))/${#plugin[@]}) '$plugin_name' found. SKIPPING..."
          STATUS SKIP
        else
          h3 "($((i+1))/${#plugin[@]}) '$plugin_name' not found. Installing"
          WP plugin install --activate "$plugin_url" --quiet
          STATUS $?
          if [ $plugin_name == 'rest-api' ]; then
            h3 "       Installing 'wp-rest-cli' WP-CLI package"
            WP package install danielbachhuber/wp-rest-cli --quiet
            STATUS $?
          fi
        fi
      done
    done <<< "$PLUGINS"
  else
    h3 "No plugin dependencies listed. SKIPPING..."
    STATUS SKIP
  fi
}

first_build() {
  h2 "Cleaning up unneeded files from initial build"
  h3 "Removing default plugins"
  WP plugin uninstall akismet hello --deactivate --quiet
  STATUS $?

  h3 "Removing unneeded themes"
  REMOVE_LIST=(twentyfourteen twentyfifteen twentysixteen)
  THEME_LIST=()
  while IFS=',' read -ra theme; do
    for i in "${!theme[@]}"; do
      REMOVE_LIST=( "${REMOVE_LIST[@]/${theme[$i]}}" )
      THEME_LIST+=("${theme[$i]}")
    done
    WP theme delete "${REMOVE_LIST[@]}" --quiet
  done <<< $THEMES
  STATUS $?

  h3 "Installing needed themes"
  WP theme install --quiet "${THEME_LIST[@]}"
  STATUS $?
}

# Config Utility Functions
# -------------------------
generate_config_for() {

case "$1" in

wp-cli)
cat > /app/wp-cli.yml <<EOF
apache_modules:
  - mod_rewrite

core config:
  dbuser: root
  dbpass: $DB_PASS
  dbname: $DB_NAME
  dbprefix: $DB_PREFIX
  dbhost: db:3306
  extra-php: |
    define('WP_DEBUG', ${WP_DEBUG,,});
    define('WP_DEBUG_LOG', ${WP_DEBUG_LOG,,});
    define('WP_DEBUG_DISPLAY', ${WP_DEBUG_DISPLAY,,});

core install:
  url: $([ "$AFTER_URL" ] && echo "$AFTER_URL" || echo localhost:8080)
  title: $DB_NAME
  admin_user: root
  admin_password: $DB_PASS
  admin_email: $ADMIN_EMAIL
  skip-email: true
EOF
;;

wordpress)
  rm -f /app/wp-config.php
  WP core config |& loglevel
  return ${PIPESTATUS[0]}
;;

esac

}

# Helpers
# --------------

RED='\033[0;31m'
GREEN='\033[0;32m'
ORANGE='\033[0;33m'
PURPLE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\E[1m'
NC='\033[0m'

h1() {
  local len=$(($(tput cols)-1))
  local input=$*
  local size=$((($len - ${#input})/2))

  for ((i = 0; i < $len; i++)); do echo -ne "${PURPLE}${BOLD}="; done; echo ""
  for ((i = 0; i < $size; i++)); do echo -n " "; done; echo -e "${NC}${BOLD}$input"
  for ((i = 0; i < $len; i++)); do echo -ne "${PURPLE}${BOLD}="; done; echo -e "${NC}"
}

h2() {
  echo -e "${ORANGE}${BOLD}==>${NC}${BOLD} $*${NC}"
}

h3() {
  printf "%b " "${CYAN}${BOLD}  ->${NC} $*"
}

h3warn() {
  printf "%b " "${RED}${BOLD}  [!]|${NC} $*" && echo ""
}

STATUS() {
  local status=$1
  if [[ $1 == 'SKIP' ]]; then
    echo ""
    return
  fi
  if [[ $status != 0 ]]; then
    echo -e "${RED}✘${NC}"
    return
  fi
  echo -e "${GREEN}✓${NC}"
}

ERROR() {
  echo -e "${RED}=> ERROR (Line $1): $2.${NC}";
  exit 1;
}

WP() {
  sudo -u www-data wp "$@"
}

loglevel() {
  [[ "$VERBOSE" == "false" ]] && return
  local IN
  while read IN; do
    echo $IN
  done
}


main
