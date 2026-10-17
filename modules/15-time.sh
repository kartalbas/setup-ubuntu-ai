# shellcheck shell=bash
# modules/15-time.sh — the clock: time zone TIMEZONE (default Europe/Zurich), NTP on (chrony if it
# is installed, else systemd-timesyncd), and GNOME's GeoIP time zone off — system-wide through a
# dconf default and for the invoking user — so the desktop cannot change the zone back.
# shellcheck source=/dev/null

TIMEZONE_DEFAULT="Europe/Zurich"

_time_dconf_profile() {
  local f=/etc/dconf/profile/user line
  ensure_dir /etc/dconf/profile 0755
  if [[ ! -f "$f" ]]; then
    printf 'user-db:user\nsystem-db:local\n' | atomic_write "$f" 0644; return
  fi
  for line in user-db:user system-db:local; do       # an existing profile keeps its own lines
    grep -qx "$line" "$f" || { backup_file "$f"; printf '%s\n' "$line" >>"$f"; }
  done
}

module_main() {
  local tz; tz="$(cfg_get TIMEZONE "$TIMEZONE_DEFAULT")"
  log_step "Time: zone ${tz}, NTP, no GNOME GeoIP time zone"
  [[ -e "/usr/share/zoneinfo/$tz" ]] || { log_error "Unknown time zone: ${tz}"; return 1; }
  if [[ "$(timedatectl show -p Timezone --value 2>/dev/null)" == "$tz" ]]; then
    log_ok "Time zone already ${tz}"
  else
    run timedatectl set-timezone "$tz"
  fi
  run timedatectl set-ntp true
  if [[ "$(systemctl list-unit-files chrony.service 2>/dev/null || true)" == *chrony.service* ]]; then
    run systemctl enable --now chrony.service
  else
    run systemctl enable --now systemd-timesyncd.service
  fi

  if have dconf; then
    _time_dconf_profile
    ensure_dir /etc/dconf/db/local.d 0755
    printf '[org/gnome/desktop/datetime]\nautomatic-timezone=false\n' \
      | atomic_write /etc/dconf/db/local.d/01-datetime 0644
    run dconf update
    if have gsettings && [[ -S "/run/user/$(id -u "$INVOKING_USER")/bus" ]]; then
      run_as_user env "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u "$INVOKING_USER")/bus" \
        gsettings set org.gnome.desktop.datetime automatic-timezone false || true
    fi
  else
    log_info "No dconf (no GNOME): nothing to switch off there."
  fi

  [[ "${DRY_RUN:-0}" == "1" ]] && return 0
  cfg_set TIMEZONE "$tz"; cfg_save
  log_ok "$(timedatectl show -p Timezone --value), NTP $(timedatectl show -p NTP --value), synchronized $(timedatectl show -p NTPSynchronized --value), /etc/localtime → $(readlink /etc/localtime)"
}
