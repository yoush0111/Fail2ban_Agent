# fail2ban-agent

서버에 올려서 실행하면 메뉴를 고르는 방식으로 fail2ban을 **설치 → 설정 → 관리**할 수 있는 대화형 쉘 스크립트입니다.
OS는 `/etc/os-release`를 읽어 자동으로 판별하므로, 어느 서버든 같은 파일 하나를 쓰면 됩니다.

## 지원 OS

| OS | 패키지 | 차단 방식 |
|---|---|---|
| Rocky / Alma / CentOS Stream 8·9 | `dnf` + EPEL (`fail2ban`, `fail2ban-firewalld`) | firewalld |
| CentOS 7 (EOL) | `yum` + EPEL (`fail2ban-systemd` 추가) | firewalld |
| Ubuntu / Debian | `apt` (`fail2ban`, `python3-systemd`) | 패키지 기본값 (nftables/iptables). ufw는 건드리지 않음 |

모든 OS에서 SSH 로그인 실패는 journal(`backend = systemd`)에서 읽습니다.

## 빠른 시작

```bash
# 1. 서버에 업로드 (경로는 어디든 상관없음)
scp fail2ban-agent.sh user@server:~

# 2. 서버에서 root 권한으로 실행
ssh user@server
sudo bash ~/fail2ban-agent.sh
```

```
[INFO] 감지된 OS: Rocky Linux 9.4 (Blue Onyx)

══ fail2ban 관리 ══
1) 설치  2) 설정  3) 관리  0) 종료
선택:
```

처음 설치하는 서버라면 **1 → 2 → 3** 순서로 진행합니다.

- 실행 권한(`chmod +x`)은 필요하지 않습니다.
- 관리 메뉴를 계속 쓸 거라면 `/root`나 `/usr/local/sbin`처럼 지워지지 않는 곳에 두세요. `/tmp`는 재부팅하면 사라질 수 있습니다.

## 메뉴 설명

### 1) 설치

- 패키지를 설치합니다. RHEL 계열은 EPEL 저장소를 먼저 추가합니다.
- **RHEL 계열은 firewalld 상태를 확인합니다.** firewalld가 꺼져 있으면 차단 목록에만 표시되고 실제로는 막히지 않기 때문입니다.
  - 꺼져 있으면 경고와 함께 현재 열려 있는(LISTEN) 포트 목록을 보여 주고, `y`를 입력해야만 켭니다.
  - 켜기 전에 SSH 포트부터 허용하므로 SSH 접속은 끊기지 않습니다.
  - 그 외 서비스 포트(웹, DB 등)는 직접 열어야 합니다. 예: `firewall-cmd --permanent --add-service=http && firewall-cmd --reload`

### 2) 설정

항목을 하나씩 물어봅니다. 그냥 Enter를 누르면 `[ ]` 안의 기본값이 적용됩니다.

| 질문 | 기본값 | 의미 |
|---|---|---|
| 차단 시간 (bantime) | `1h` | 차단을 유지하는 시간 |
| 실패 집계 구간 (findtime) | `10m` | 실패 횟수를 세는 시간 범위 |
| 허용 실패 횟수 (maxretry) | `5` | 이 횟수만큼 실패하면 차단 |
| SSH 포트 | 자동 감지 (`sshd -T`) | 포트를 바꾼 서버도 자동으로 잡힘 |
| 차단 예외 IP | 현재 접속 중인 IP | 사내 공인 IP 등, 공백으로 구분 |
| recidive 사용 | 아니오 | 상습 IP를 1주일 차단 (`bantime.increment`와 기능이 겹침) |

- 시간은 `600`(초), `10m`, `1h`, `1d`, `1w` 형식으로 입력합니다.
- IP는 `1.2.3.4`, `211.10.20.0/24`, `2001:db8::/32` 형식을 받습니다.
- 재차단될 때마다 차단 시간이 늘어나며(`bantime.increment`), 최대 1주일입니다.

결과는 `/etc/fail2ban/jail.d/local.conf`에 저장됩니다.

1. 기존 파일이 있으면 `local.conf.bak.YYYYMMDDHHMMSS`로 백업합니다.
2. `fail2ban-client -t`로 문법을 검사합니다.
3. 검사에 실패하면 **이전 상태로 자동 원복**하고 오류를 보여 줍니다.
4. 통과하면 fail2ban을 부팅 시 자동 시작하도록 등록하고 재시작합니다.

> 설정 메뉴를 다시 실행하면 `local.conf`를 **새로 덮어씁니다.** 직접 수정한 내용은 백업 파일에만 남습니다.

### 3) 관리

```
1) 상태 보기  2) 차단 해제  3) 예외 IP 보기  4) 예외 IP 추가  5) 수동 차단  6) 로그 보기  0) 뒤로
```

| 메뉴 | 동작 |
|---|---|
| 상태 보기 | 활성 jail 목록, sshd 실패 횟수와 차단 IP 목록. RHEL은 firewalld 차단 규칙도 표시 |
| 차단 해제 | 입력한 IP의 차단을 모든 jail에서 해제 (`fail2ban-client unban`) |
| 예외 IP 보기 | 현재 적용 중인 차단 예외 IP 목록. fail2ban이 꺼져 있으면 `local.conf`의 값을 표시 |
| 예외 IP 추가 | `local.conf`의 `ignoreip`에 추가 → 검사 → reload (실패 시 원복) |
| 수동 차단 | sshd jail로 즉시 차단. 내 IP를 입력하면 한 번 더 확인 |
| 로그 보기 | `/var/log/fail2ban.log` 최근 50줄 (파일이 없으면 journal) |

IP 입력 칸에서 아무것도 입력하지 않고 Enter를 누르면 취소됩니다.

## 동작 확인

설정을 마친 뒤, **차단 예외에 없는 다른 PC**에서 SSH 비밀번호를 5번 이상 틀려 봅니다.
그다음 관리 → 상태 보기에서 그 IP가 `Banned IP list`에 나오면 정상입니다.

## 트러블슈팅

| 증상 | 확인 사항 |
|---|---|
| 설정 단계에서 검사 실패 | 화면에 나온 오류 확인. Ubuntu는 `python3-systemd`가 설치됐는지, CentOS 7은 `fail2ban-systemd`가 설치됐는지 확인 |
| 차단 목록에 있는데 접속이 계속됨 | firewalld가 실행 중인지, 앞단 로드밸런서나 프록시 때문에 실제 IP가 안 보이는지 확인 |
| 로그인 실패가 집계되지 않음 | `journalctl _COMM=sshd \| grep Failed`로 로그를 확인한 뒤 `fail2ban-regex systemd-journal sshd`로 필터 테스트 |
| OpenSSH 9.8 이상에서 집계 안 됨 | 로그가 `sshd-session` 이름으로 남음. fail2ban 1.1.0 이상 필요 |
| 내 IP가 차단됨 | 콘솔 등 다른 경로로 접속해 관리 → 차단 해제 후 예외 IP 추가 |

## 개발

```bash
bash -n fail2ban-agent.sh    # 문법 검사
bash test_validators.sh      # 입력 검증 함수 테스트
```

`test_validators.sh`는 개발 PC에서만 쓰는 테스트이며, 서버에 올릴 필요가 없습니다.
파일은 반드시 LF 줄바꿈으로 저장하세요. CRLF로 저장되면 서버에서 실행이 깨집니다.

자세한 배경 설명은 [fail2ban 설치 및 설정 가이드](fail2ban%20설치%20및%20설정%20가이드.md)를 참고하세요.
