#!/usr/bin/env bash
# 입력 검증 함수 자가 점검: bash test_validators.sh
. "$(dirname "$0")/fail2ban-agent.sh"

fail=0
ok()  { "$@" || { echo "FAIL (기대: 통과): $*"; fail=1; }; }
bad() { ! "$@" || { echo "FAIL (기대: 거부): $*"; fail=1; }; }

ok  valid_ip 211.211.123.12
ok  valid_ip 127.0.0.1/8
ok  valid_ip 192.168.0.0/16
ok  valid_ip 010.1.1.1
ok  valid_ip ::1
ok  valid_ip 2001:db8::/32
bad valid_ip 256.1.1.1
bad valid_ip 1.2.3.4/33
bad valid_ip 1.2.3.4/
bad valid_ip 1.2.3
bad valid_ip abc
bad valid_ip ""
ok  valid_ip_list "1.2.3.4 10.0.0.0/8"
ok  valid_ip_list ""
bad valid_ip_list "1.2.3.4 nope"
ok  valid_time 1h
ok  valid_time 600
bad valid_time 1x
ok  valid_count 5
bad valid_count 0
ok  valid_port 22
bad valid_port 0
bad valid_port 70000

# logtarget: 나중에 읽힌 설정이 우선
F2B_DIR=$(mktemp -d)
mkdir -p "$F2B_DIR/fail2ban.d"
printf '[Definition]\nlogtarget = /var/log/fail2ban.log\n' > "$F2B_DIR/fail2ban.conf"
[[ $(fail2ban_logtarget) == /var/log/fail2ban.log ]] || { echo "FAIL: logtarget 기본"; fail=1; }
printf '[Definition]\nlogtarget = SYSTEMD-JOURNAL  \n' > "$F2B_DIR/fail2ban.d/01-journal.conf"
[[ $(fail2ban_logtarget) == SYSTEMD-JOURNAL ]] || { echo "FAIL: logtarget 덮어쓰기"; fail=1; }
rm -rf "$F2B_DIR"

# 차단 방식: firewalld 꺼진 RHEL만 iptables/nftables 지정
FW_ACTIVE=1
systemctl() { [[ $1 == is-active ]] && return $FW_ACTIVE; return 1; }
OS_FAMILY=rhel OS_MAJOR=7
[[ $(ban_actions) == *"banaction = iptables-multiport"* ]] || { echo "FAIL: CentOS 7 iptables"; fail=1; }
[[ $(rhel_packages) == "fail2ban-server iptables fail2ban-systemd" ]] || { echo "FAIL: CentOS 7 패키지"; fail=1; }
OS_MAJOR=9
[[ $(ban_actions) == *"banaction = nftables-multiport"* ]] || { echo "FAIL: Rocky nftables"; fail=1; }
FW_ACTIVE=0
[[ -z $(ban_actions) ]] || { echo "FAIL: firewalld 실행 중이면 기본값"; fail=1; }
[[ $(rhel_packages) == "fail2ban fail2ban-firewalld python3-systemd" ]] || { echo "FAIL: firewalld 패키지"; fail=1; }
OS_FAMILY=debian FW_ACTIVE=1
[[ -z $(ban_actions) ]] || { echo "FAIL: Ubuntu는 기본값"; fail=1; }

[[ $fail == 0 ]] && echo "all passed"
exit $fail
