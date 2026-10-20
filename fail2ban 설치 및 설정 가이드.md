# fail2ban 설치 및 설정 가이드 (CentOS / Rocky Linux)

## 1. fail2ban이란?

로그 파일을 감시하다가 로그인 실패 같은 기록이 정해진 시간 안에 일정 횟수를 넘으면, 해당 IP를 방화벽으로 일정 시간 자동 차단하는 침입 방지 도구입니다. SSH 무차별 대입(brute-force) 공격 방어에 주로 쓰이며, 리눅스 서버에서 사실상 표준처럼 널리 사용됩니다.

- 최신 버전: 1.1.0
- 라이선스: GPL v2

### 장점

- 설치와 설정이 쉽고 가볍다.
- SSH, Nginx, Apache, Postfix, Dovecot 등 주요 서비스용 필터가 기본 포함되어 있다.
- 로그만 남기면 정규식으로 어떤 서비스든 커스텀 필터를 만들 수 있다.
- 단순 공격으로 생기는 로그 노이즈와 서버 부하를 크게 줄여 준다.
- 차단 시 메일 알림, Cloudflare 연동 등 다양한 action을 지원한다.

### 단점

- 공격이 로그에 찍힌 뒤에 차단하는 사후 방어 방식이다.
- 수천 개 IP로 분산해 천천히 시도하는 공격에는 효과가 약하다.
- IPv6는 주소 공간이 넓어 IP 단위 차단의 실효성이 떨어진다.
- 트래픽이 많은 서버에서는 로그 파싱으로 CPU를 꽤 사용할 수 있다.
- 정규식을 잘못 작성하면 정상 사용자가 차단되거나 공격을 놓친다.
- 리버스 프록시, Docker 환경에서는 실제 클라이언트 IP 처리가 까다롭다.

### 권장 구성

SSH 키 인증 + 비밀번호 로그인 비활성화 + 필요한 포트만 여는 방화벽 + fail2ban. 대안으로는 커뮤니티 위협 IP 공유 기능이 있는 CrowdSec이 있습니다.

---

## 2. 인증 로그 경로 (CentOS / Rocky)

|배포판|인증 로그 경로|
|---|---|
|Debian / Ubuntu|`/var/log/auth.log`|
|CentOS / Rocky (RHEL 계열)|`/var/log/secure`|

```bash
sudo tail -f /var/log/secure
sudo grep "Failed password" /var/log/secure
```

- fail2ban은 배포판을 자동 인식하므로 경로를 직접 지정하지 않아도 됩니다.
- EPEL 패키지는 기본적으로 `backend = systemd`(journald)를 사용하므로, 실제로는 `/var/log/secure` 파일 대신 journal을 읽습니다. 그대로 두는 것을 권장합니다.
- `/var/log/secure`는 rsyslog가 생성합니다. 최소 설치로 rsyslog가 없으면 journal에서 확인합니다.

```bash
journalctl -u sshd -f
journalctl _COMM=sshd --since "1 hour ago" | grep Failed
```

---

## 3. 설치 및 설정

### 3-0. OS 버전 확인

```bash
cat /etc/redhat-release
```

> CentOS 7은 2024년 6월 지원 종료(EOL). 기본 미러가 막혀 설치가 실패할 수 있으며, 보안 패치가 없으므로 Rocky / Alma 등으로의 이전을 검토하는 것이 좋습니다. CentOS Stream 8/9는 Rocky와 동일한 방법을 따릅니다.

### 3-1. EPEL 저장소 추가

```bash
# Rocky 8/9
sudo dnf install -y epel-release

# CentOS 7
sudo yum install -y epel-release
```

### 3-2. fail2ban 설치

```bash
# Rocky 8/9
sudo dnf install -y fail2ban fail2ban-firewalld

# CentOS 7 (journald를 읽으려면 fail2ban-systemd 필요)
sudo yum install -y fail2ban fail2ban-firewalld fail2ban-systemd
```

### 3-3. firewalld 실행 확인

fail2ban은 firewalld를 통해 차단합니다. firewalld가 꺼져 있으면 차단 목록에만 표시되고 실제로는 막히지 않습니다.

```bash
sudo systemctl enable --now firewalld
sudo firewall-cmd --state        # running 이어야 함
sudo firewall-cmd --list-all     # SSH 포트가 열려 있는지 확인
```

### 3-4. 패키지 기본 설정 확인

```bash
ls /etc/fail2ban/jail.d/
cat /etc/fail2ban/jail.d/00-firewalld.conf
cat /etc/fail2ban/jail.d/00-systemd.conf   # 있는 경우
```

- `00-firewalld.conf`: 차단 방식(banaction)을 firewalld용으로 지정
- `00-systemd.conf`: 로그 읽기 방식(backend)을 journald로 지정
- 이 파일들은 수정하지 않고, 내 설정은 별도 파일로 만듭니다.

### 3-5. 내 설정 파일 작성

`local.conf`는 원래 없는 파일이며, 직접 새로 만드는 것입니다. `vi`로 열면 빈 파일이 열리고 `:wq`로 저장하면 생성됩니다.

```bash
sudo vi /etc/fail2ban/jail.d/local.conf
```

```ini
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5
bantime.increment = true
bantime.maxtime   = 1w
# 관리자 IP / 사내 대역은 반드시 예외 처리
ignoreip = 127.0.0.1/8 ::1 211.211.123.12

[sshd]
enabled = true
backend = systemd
port    = ssh
# SSH 포트를 바꿨다면: port = 2222
```

|항목|의미|
|---|---|
|`bantime`|차단 유지 시간|
|`findtime`|실패 횟수를 세는 시간 범위|
|`maxretry`|이 횟수만큼 실패하면 차단|
|`bantime.increment`|재차단 시 차단 시간을 점점 늘림|
|`bantime.maxtime`|늘어나는 차단 시간의 최대값|
|`ignoreip`|차단하지 않을 IP 목록|

파일 이름 규칙:

- 확장자는 `.conf` 또는 `.local`이어야 읽힙니다.
- `jail.d` 안의 파일은 이름순으로 읽히고, 나중에 읽힌 설정이 우선합니다. `local.conf`는 `00-...` 파일보다 뒤에 읽히므로 내 설정이 적용됩니다.

### 3-6. 설정 검사 후 시작

```bash
sudo fail2ban-client -t                 # 문법 검사 (OK 나와야 함)
sudo systemctl enable --now fail2ban
sudo systemctl status fail2ban
```

---

## 4. ignoreip 설정 방법

### 기본 사용법

사내 공인 IP가 `211.211.123.12`라면 다음과 같이 뒤에 한 칸 띄우고 적으면 됩니다.

```ini
ignoreip = 127.0.0.1/8 ::1 211.211.123.12
```

- 앞의 `127.0.0.1/8 ::1`은 "서버 자기 자신"을 뜻하는 고정값이므로 항상 그대로 둡니다.
- 공인 IP 하나만 넣을 때는 `/` 표기를 붙일 필요가 없습니다.
- 여러 개는 공백으로 이어 씁니다.

```ini
ignoreip = 127.0.0.1/8 ::1 211.211.123.12 211.211.123.13
```

### `127.0.0.1/8 ::1`의 의미

두 개의 별도 항목입니다.

- `127.0.0.1/8`: 127로 시작하는 IPv4 주소 전체(루프백, 서버 자기 자신)
- `::1`: IPv6의 루프백 주소(IPv4의 127.0.0.1과 같은 의미)

### CIDR 표기 (`/숫자`)

IP 뒤의 `/숫자`는 범위를 뜻합니다. 숫자가 작을수록 범위가 넓습니다.

|표기|포함 범위|IP 개수|
|---|---|---|
|`211.10.20.30` 또는 `/32`|211.10.20.30 하나|1|
|`211.10.20.0/24`|211.10.20.0 ~ 211.10.20.255|256|
|`192.168.0.0/16`|192.168.0.0 ~ 192.168.255.255|65,536|
|`127.0.0.1/8`|127.0.0.0 ~ 127.255.255.255|약 1,600만|

### 주의사항

- **주석은 반드시 별도 줄로**: `# 주석`과 `ignoreip = ...`가 한 줄에 있으면 줄 전체가 주석 처리되어 적용되지 않습니다.
- **사설 대역은 필요할 때만**: 서버가 사내망에 있고 내부 PC에서 사설 IP로 접속할 때만 `192.168.0.0/16` 같은 대역을 넣습니다. 외부 IDC / 클라우드 서버라면 넣지 않습니다.
- **유동 IP 주의**: 재택, 모바일 등 IP가 바뀌는 환경은 예외 처리가 안 되므로 SSH 키 인증을 함께 쓰는 것이 좋습니다.

### 사내 공인 IP 확인 방법

```bash
# 사무실 PC에서
curl ifconfig.me

# 서버에서 실제 접속해 온 IP 확인
sudo journalctl -u sshd | grep Accepted
```

### 변경 후 반영 및 확인

```bash
sudo fail2ban-client -t
sudo fail2ban-client reload
sudo fail2ban-client get sshd ignoreip
```

---

## 5. 동작 확인 및 관리

```bash
sudo fail2ban-client status              # 활성 jail 목록 (sshd 보여야 함)
sudo fail2ban-client status sshd         # 실패 횟수, 차단된 IP 목록
sudo firewall-cmd --list-rich-rules      # 실제 방화벽 차단 규칙
sudo tail -f /var/log/fail2ban.log       # fail2ban 로그

# 차단 해제
sudo fail2ban-client set sshd unbanip 1.2.3.4
```

**차단 테스트**: ignoreip에 없는 다른 PC에서 틀린 비밀번호로 SSH 접속을 5번 이상 시도한 뒤, 위 명령으로 차단 여부를 확인합니다.

---

## 6. 선택: 상습 IP 장기 차단 (recidive)

`local.conf`에 추가합니다. `bantime.increment`와 기능이 겹치므로 둘 중 하나만 사용해도 충분합니다.

```ini
[recidive]
enabled  = true
bantime  = 1w
findtime = 1d
maxretry = 3
```

---

## 7. 트러블슈팅

|증상|확인 사항|
|---|---|
|jail이 시작되지 않음|`sudo journalctl -u fail2ban -n 50` 으로 오류 확인. CentOS 7은 `fail2ban-systemd` 누락 여부 확인|
|차단 목록에 있는데 접속이 계속됨|firewalld 실행 여부, 앞단 로드밸런서 / 프록시로 실제 IP가 안 보이는지 확인|
|로그인 실패가 집계되지 않음|`journalctl -u sshd \| grep Failed` 로 로그 확인 후 `fail2ban-regex systemd-journal sshd` 로 필터 테스트|
|내 IP가 차단됨|다른 경로(콘솔 등)로 접속해 `unbanip` 실행 후 `ignoreip`에 추가|