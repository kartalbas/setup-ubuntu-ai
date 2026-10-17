# shellcheck shell=bash
# modules/70-bench.sh — what the public agent benchmarks need on this machine:
# Docker (each task runs in its own container) and Harbor, the harness that
# runs SWE-bench Verified / Pro and Terminal-Bench with an agent such as
# OpenCode or Claude Code against this server and grades the result with the
# benchmark's own tests. benchmarks/harbor_bench.sh runs them.
#   HARBOR_VERSION   the Harbor release from PyPI (pinned; bump deliberately)
# shellcheck source=/dev/null

HARBOR_VERSION_DEFAULT="0.24.0"

_bench_harbor() { as_user env PATH="$INVOKING_HOME/.local/bin:/usr/bin:/bin" harbor "$@"; }

module_main() {
  log_step "Benchmark harness: Docker + Harbor"
  local ver; ver="$(cfg_get HARBOR_VERSION "$HARBOR_VERSION_DEFAULT")"
  apt_install docker.io docker-buildx pipx
  run systemctl enable --now docker.service
  if ! id -nG "$INVOKING_USER" | tr ' ' '\n' | grep -qx docker; then
    narrate "Adding ${INVOKING_USER} to the docker group (new logins get it; sudo -u gets it at once)."
    run usermod -aG docker "$INVOKING_USER"
  fi
  if [[ "$(_bench_harbor --version 2>/dev/null)" == *"$ver"* ]]; then
    log_ok "Harbor ${ver} already installed"
  else
    narrate "Installing Harbor ${ver} for ${INVOKING_USER} (pipx, ~/.local/bin/harbor)."
    run_as_user env PATH="$INVOKING_HOME/.local/bin:/usr/bin:/bin" pipx install --force "harbor==${ver}" \
      || { log_error "Harbor ${ver} did not install."; return 1; }
  fi
  [[ "${DRY_RUN:-0}" == "1" ]] && return 0
  run_as_user docker info --format 'Docker {{.ServerVersion}}, root {{.DockerRootDir}}' || { log_error "Docker does not answer for ${INVOKING_USER}."; return 1; }
  log_ok "Harbor: $(_bench_harbor --version 2>/dev/null | head -1) — run the benchmarks with benchmarks/harbor_bench.sh"
}

module_uninstall() {
  log_step "Removing Harbor (Docker stays)"
  run_as_user env PATH="$INVOKING_HOME/.local/bin:/usr/bin:/bin" pipx uninstall harbor || true
  log_ok "Harbor removed. Docker and its images stay: sudo apt purge docker.io; docker system prune -a frees them."
}
