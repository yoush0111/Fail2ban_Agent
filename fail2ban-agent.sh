#!/usr/bin/env bash
# fail2ban 설치·설정·관리 대화형 스크립트
# 지원: CentOS 7 / Rocky·Alma·CentOS Stream 8·9 / Ubuntu·Debian
# 사용법: sudo bash fail2ban-agent.sh
set -uo pipefail

F2B_DIR=/etc/fail2ban
CONF=$F2B_DIR/jail.d/local.conf
OS_FAMILY="" PKG="" OS_NAME="" OS_MAJOR=""

info() { printf '\033[32m[INFO]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[WARN]\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[31m[ERROR]\033[0m %s\n' "$*" >&2; }

# ── 입력 / 검증 ──────────────────────────────────────────────

# 기본값이 있는 입력: ask "질문" "기본값"
ask() {
  local v
  read -rp "$1 [$2]: " v || exit 0
  echo "${v:-$2}"
}

confirm() {
  local v
  read -rp "$1 (y/N): " v || exit 0
  [[ $v =~ ^[yY]$ ]]
}

# 검증을 통과할 때까지 반복 입력: ask_valid 검증함수 "질문" "기본값"
ask_valid() {
  local v
  while true; do
    v=$(ask "$2" "$3")
    "$1" "$v" && { echo "$v"; return; }
    warn "형식이 올바르지 않습니다: $v"
  done
}

# IPv4 / IPv6 / CIDR 형식 검사
valid_ip() {
  local addr=${1%%/*} mask=""
  if [[ $1 == */* ]]; then
    mask=${1#*/}
    [[ $mask =~ ^[0-9]{1,3}$ ]] || return 1
  fi
  if [[ $addr =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]]; then
    local o
    for o in "${BASH_REMATCH[@]:1}"; do (( 10#$o <= 255 )) || return 1; done
    [[ -z $mask ]] || (( 10#$mask <= 32 ))
  elif [[ $addr == *:* && $addr =~ ^[0-9a-fA-F:]+$ ]]; then
    [[ -z $mask ]] || (( 10#$mask <= 128 ))
  else
    return 1
  fi
}

# 공백으로 구분된 IP 목록 (빈 값 허용)
valid_ip_list() {
  local ip
  # shellcheck disable=SC2086  # 의도적인 단어 분리
  for ip in $1; do valid_ip "$ip" || return 1; done
}

valid_time()  { [[ $1 =~ ^[0-9]+[smhdw]?$ ]]; }
valid_count() { [[ $1 =~ ^[1-9][0-9]*$ ]]; }
valid_port()  { [[ $1 =~ ^[0-9]{1,5}$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 )); }

# 관리 메뉴용 IP 입력 (빈 값이면 취소)
read_ip() {
  local ip
  read -rp "IP (빈 값이면 취소): " ip || exit 0
  [[ -z $ip ]] && return 1
  valid_ip "$ip" || { warn "IP 형식이 올바르지 않습니다: $ip"; return 1; }
  echo "$ip"
}

# ── 환경 감지 ────────────────────────────────────────────────

detect_os() {
  [[ -r /etc/os-release ]] || { err "/etc/os-release 를 찾을 수 없습니다"; exit 1; }
  # shellcheck disable=SC1091
  . /etc/os-release
  OS_NAME="${PRETTY_NAME:-$ID}"
  OS_MAJOR="${VERSION_ID%%.*}"
  case "$ID" in
    rocky|almalinux|centos)
      OS_FAMILY=rhel
      if [[ $OS_MAJOR == 7 ]]; then PKG=yum; else PKG=dnf; fi ;;
    ubuntu|debian)
      OS_FAMILY=debian; PKG=apt-get ;;
    *) err "지원하지 않는 OS: $OS_NAME"; exit 1 ;;
  esac
}

ssh_port() {
  local p
  p=$(sshd -T 2>/dev/null | awk '$1=="port"{print $2; exit}')
  echo "${p:-22}"
}

# 지금 SSH로 접속해 온 IP (sudo는 SSH_CLIENT를 지우므로 who -m 으로 보완)
client_ip() {
  local ip=${SSH_CLIENT:-}
  ip=${ip%% *}
  [[ -n $ip ]] || ip=$(who -m 2>/dev/null | sed -n 's/.*(\(.*\)).*/\1/p')
  valid_ip "$ip" && echo "$ip"
}

require_fail2ban() {
  command -v fail2ban-client >/dev/null && return 0
  err "fail2ban이 설치되어 있지 않습니다. '설치' 메뉴를 먼저 진행하세요"
  return 1
}

# ── 1) 설치 ──────────────────────────────────────────────────

# firewalld가 꺼져 있으면 경고 후 확인받고 켠다 (SSH 포트는 켜기 전에 허용)
ensure_firewalld() {
  local port=$1
  if systemctl is-active --quiet firewalld; then
    info "firewalld 실행 중"
    return 0
  fi
  warn "firewalld가 꺼져 있습니다. 켜면 허용되지 않은 포트는 모두 막힙니다."
  warn "현재 LISTEN 중인 포트 (SSH ${port}/tcp 는 자동 허용):"
  ss -tlnu >&2
  if ! confirm "firewalld를 켤까요?"; then
    warn "firewalld 없이는 차단 목록에만 표시되고 실제로는 막히지 않습니다"
    return 1
  fi
  firewall-offline-cmd --add-port="${port}/tcp" >/dev/null || { err "SSH 포트 허용 실패, firewalld를 켜지 않습니다"; return 1; }
  systemctl enable --now firewalld && info "firewalld 시작 (${port}/tcp 허용)"
}

do_install() {
  if [[ $OS_FAMILY == rhel ]]; then
    local pkgs=(fail2ban fail2ban-firewalld)
    if [[ $OS_MAJOR == 7 ]]; then
      warn "CentOS 7은 EOL(2024-06)입니다. 미러 문제로 설치가 실패할 수 있습니다."
      pkgs+=(fail2ban-systemd)
    fi
    if ! { $PKG install -y epel-release && $PKG install -y "${pkgs[@]}"; }; then
      err "패키지 설치 실패"; return 1
    fi
    ensure_firewalld "$(ssh_port)"
  else
    # python3-systemd: journal(backend = systemd)을 읽는 데 필요
    if ! { apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y fail2ban python3-systemd; }; then
      err "패키지 설치 실패"; return 1
    fi
  fi
  info "설치 완료: $(fail2ban-client --version 2>&1 | head -n1)"
  info "다음으로 '설정' 메뉴를 진행하세요"
}

# ── 2) 설정 ──────────────────────────────────────────────────

# 새 내용으로 local.conf 교체 → 문법 검사 → 실패 시 원복, 성공 시 restart/reload
apply_conf() {
  local content=$1 action=$2 backup="" out
  if [[ -f $CONF ]]; then
    backup="$CONF.bak.$(date +%Y%m%d%H%M%S)"
    cp -p "$CONF" "$backup"
  fi
  printf '%s\n' "$content" > "$CONF"
  if ! out=$(fail2ban-client -t 2>&1); then
    err "설정 검사 실패, 이전 상태로 되돌립니다:"
    echo "$out" >&2
    if [[ -n $backup ]]; then mv "$backup" "$CONF"; else rm -f "$CONF"; fi
    return 1
  fi
  [[ -n $backup ]] && info "기존 설정 백업: $backup"
  if [[ $action == restart ]]; then
    systemctl enable fail2ban >/dev/null 2>&1
    systemctl restart fail2ban && info "fail2ban 재시작: $(systemctl is-active fail2ban)"
  else
    fail2ban-client reload && info "설정 반영 완료"
  fi
}

do_configure() {
  require_fail2ban || return 1
  local bantime findtime maxretry port myip admin content
  bantime=$(ask_valid valid_time "차단 시간 (bantime)" 1h)
  findtime=$(ask_valid valid_time "실패 집계 구간 (findtime)" 10m)
  maxretry=$(ask_valid valid_count "허용 실패 횟수 (maxretry)" 5)
  port=$(ask_valid valid_port "SSH 포트" "$(ssh_port)")
  myip=$(client_ip) && info "현재 접속 IP: $myip (차단 예외 기본값으로 제안)"
  admin=$(ask_valid valid_ip_list "차단 예외 IP (공백 구분, 사내 공인 IP 등)" "${myip:-}")
  [[ -z $admin ]] && warn "차단 예외 IP가 없습니다. 비밀번호를 여러 번 틀리면 본인도 차단됩니다."

  content=$(cat <<EOF
# Generated by fail2ban-agent.sh ($(date '+%F %T'))
[DEFAULT]
bantime  = $bantime
findtime = $findtime
maxretry = $maxretry
bantime.increment = true
bantime.maxtime   = 1w
ignoreip = 127.0.0.1/8 ::1 $admin

[sshd]
enabled = true
backend = systemd
port    = $port
EOF
)
  if confirm "상습 IP 장기 차단(recidive)을 켤까요? (bantime.increment와 기능이 겹침)"; then
    content+=$(recidive_section)
  fi
  apply_conf "$content" restart
}

# fail2ban 자체 로그 위치 (나중에 읽힌 설정이 우선)
fail2ban_logtarget() {
  cat "$F2B_DIR/fail2ban.conf" "$F2B_DIR/fail2ban.local" \
      "$F2B_DIR"/fail2ban.d/*.conf "$F2B_DIR"/fail2ban.d/*.local 2>/dev/null \
    | sed -n 's/^[[:space:]]*logtarget[[:space:]]*=[[:space:]]*\(.*[^[:space:]]\)[[:space:]]*$/\1/p' \
    | tail -n1
}

# recidive는 journal이 아니라 fail2ban 로그 파일을 읽는다 (backend = auto).
# 이 파일은 fail2ban 첫 실행 때 생기므로, 설치 직후엔 없어서 문법 검사가 실패한다 → 미리 만든다
recidive_section() {
  local log
  log=$(fail2ban_logtarget)
  if [[ $log != /* ]]; then
    warn "fail2ban 로그가 파일이 아니라서 (logtarget = ${log:-없음}) recidive를 건너뜁니다"
    return 1
  fi
  if [[ ! -e $log ]]; then
    touch "$log" && chmod 600 "$log"
    # SELinux: root가 만든 파일은 var_log_t 라서 fail2ban이 쓰지 못할 수 있음
    command -v restorecon >/dev/null && restorecon "$log"
  fi
  printf '\n\n[recidive]\nenabled  = true\nbackend  = auto\nlogpath  = %s\nbantime  = 1w\nfindtime = 1d\nmaxretry = 3' "$log"
}

# ── 3) 관리 ──────────────────────────────────────────────────

show_status() {
  fail2ban-client status
  fail2ban-client status sshd
  if [[ $OS_FAMILY == rhel ]] && systemctl is-active --quiet firewalld; then
    echo "── firewalld rich rules ──"
    firewall-cmd --list-rich-rules
  fi
}

# 실행 중이면 실제 적용값, 아니면 설정 파일 값
show_ignoreip() {
  fail2ban-client get sshd ignoreip 2>/dev/null && return 0
  warn "fail2ban이 실행 중이 아니라 설정 파일 값을 표시합니다"
  grep '^ignoreip' "$CONF" 2>/dev/null || err "$CONF 에 ignoreip 설정이 없습니다"
}

add_ignoreip() {
  if ! grep -q '^ignoreip' "$CONF" 2>/dev/null; then
    err "$CONF 에 ignoreip 줄이 없습니다. 먼저 '설정' 메뉴를 진행하세요"
    return 1
  fi
  local ip
  ip=$(read_ip) || return 0
  apply_conf "$(sed "s|^ignoreip[[:space:]]*=.*|& $ip|" "$CONF")" reload \
    && fail2ban-client get sshd ignoreip
}

manual_ban() {
  local ip
  ip=$(read_ip) || return 0
  if [[ $ip == "$(client_ip)" ]] && ! confirm "현재 접속 중인 본인 IP입니다. 정말 차단할까요?"; then
    return 0
  fi
  fail2ban-client set sshd banip "$ip"
}

show_log() {
  if [[ -f /var/log/fail2ban.log ]]; then
    tail -n 50 /var/log/fail2ban.log
  else
    journalctl -u fail2ban -n 50 --no-pager
  fi
}

do_manage() {
  require_fail2ban || return 1
  local c ip
  while true; do
    echo
    echo "── 관리 ──"
    echo "1) 상태 보기  2) 차단 해제  3) 예외 IP 보기  4) 예외 IP 추가  5) 수동 차단  6) 로그 보기  0) 뒤로"
    read -rp "선택: " c || exit 0
    case $c in
      1) show_status ;;
      2) ip=$(read_ip) && fail2ban-client unban "$ip" ;;
      3) show_ignoreip ;;
      4) add_ignoreip ;;
      5) manual_ban ;;
      6) show_log ;;
      0) return ;;
      *) warn "잘못된 선택: $c" ;;
    esac
  done
}

# ── 메인 ─────────────────────────────────────────────────────

main() {
  [[ $EUID -eq 0 ]] || { err "root 권한이 필요합니다: sudo bash $0"; exit 1; }
  detect_os
  info "감지된 OS: $OS_NAME"
  local c
  while true; do
    echo
    echo "══ fail2ban 관리 ══"
    echo "1) 설치  2) 설정  3) 관리  0) 종료"
    read -rp "선택: " c || exit 0
    case $c in
      1) do_install ;;
      2) do_configure ;;
      3) do_manage ;;
      0) exit 0 ;;
      *) warn "잘못된 선택: $c" ;;
    esac
  done
}

# source 로 불러올 때(테스트)는 실행하지 않음
[[ ${BASH_SOURCE[0]} == "$0" ]] && main "$@"
