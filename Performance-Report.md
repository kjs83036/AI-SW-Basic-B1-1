# 수행 내역서 — 시스템 관제 자동화 스크립트 개발

## 개발 환경
- 호스트: macOS (Intel x86_64)
- 가상화: OrbStack 2.0.5
- 게스트 OS: **Ubuntu 24.04.4 LTS** (GLIBC 2.39)
  - 사유: 제공된 `agent-app` 바이너리가 GLIBC 2.38 이상을 요구하여 Ubuntu 22.04(GLIBC 2.35)에서는
    실행 불가. PDF의 "Ubuntu 22.04 LTS **또는 동등 리눅스 환경**" 조건에 따라 24.04로 진행.
- OrbStack 머신명: `agent-lab`
- 방화벽 선택: **UFW**
- 제공 앱 실파일명: **`agent-app`** (PDF 본문 표기 `agent_app.py`와 다름 — 실제 제공 산출물 기준)

## sudo 사용 원칙 (제약 사항 충족 증거)
PDF 제약 "필요한 경우에만 sudo, 가능한 일반 계정으로 진행" 을 다음과 같이 운영했다.

| Phase | sudo 사용 명령 | 근거(왜 root 필수) |
|-------|---------------|--------------------|
| 1 | `apt-get install` | 패키지 설치 → `/usr/`, `/etc/`, `/var/` 쓰기 |
| 2 | `tee /etc/ssh/sshd_config.d/10-agent.conf`, `systemctl restart ssh` | `/etc/` 쓰기, systemd 서비스 제어 |
| 3 | `ufw …` | 커널 netfilter 규칙 |
| 4 | `groupadd/useradd/usermod/chpasswd` | 시스템 사용자 DB |
| 5 | `mkdir /var/log/agent-app`, `chown agent-admin:agent-core …` | `/var/log/` 쓰기, 타사용자 소유권 부여 |
| 6 | `tee /etc/profile.d/agent-env.sh` | `/etc/` 쓰기 |
| 10 | `systemctl enable --now cron` | systemd 서비스 제어 |

그 외 **Phase 7~9 와 Phase 10의 crontab 등록** 등 작업은 모두 해당 역할 계정 본인이 sudo 없이
수행함:
- agent-admin: 자기 홈 아래 디렉토리 생성, chgrp/chmod/setfacl (소유자이므로), 키 파일 작성,
  agent-app 배치, agent-app 실행, 자기 crontab 편집.
- agent-dev: monitor.sh 작성·배치 후 chgrp agent-core / chmod 750 (소유자이므로).

---

## 필수 증거 자료 체크리스트

### 1) SSH 포트 변경(20022) 및 Root 원격 접속 차단

```text
$ sudo sshd -T | grep -E '^(port|permitrootlogin) '
port 20022
permitrootlogin no

$ sudo ss -tulnp | grep ssh
tcp   LISTEN 0  128   0.0.0.0:20022   0.0.0.0:*   users:(("sshd",pid=3839,fd=3))
tcp   LISTEN 0  128      [::]:20022      [::]:*   users:(("sshd",pid=3839,fd=4))
```

설정 파일: `/etc/ssh/sshd_config.d/10-agent.conf`
```
Port 20022
PermitRootLogin no
```

### 2) UFW 활성화 및 20022/tcp, 15034/tcp만 허용

```text
$ sudo ufw status verbose
Status: active
Logging: on (low)
Default: deny (incoming), allow (outgoing), deny (routed)
New profiles: skip

To                         Action      From
--                         ------      ----
20022/tcp                  ALLOW IN    Anywhere
15034/tcp                  ALLOW IN    Anywhere
20022/tcp (v6)             ALLOW IN    Anywhere (v6)
15034/tcp (v6)             ALLOW IN    Anywhere (v6)
```

### 3) 계정/그룹 생성

```text
$ id agent-admin
uid=1000(agent-admin) gid=1002(agent-admin) groups=1002(agent-admin),1000(agent-common),1001(agent-core)

$ id agent-dev
uid=1001(agent-dev) gid=1003(agent-dev) groups=1003(agent-dev),1000(agent-common),1001(agent-core)

$ id agent-test
uid=1002(agent-test) gid=1004(agent-test) groups=1004(agent-test),1000(agent-common)

$ getent group agent-common agent-core
agent-common:x:1000:agent-admin,agent-dev,agent-test
agent-core:x:1001:agent-admin,agent-dev
```

요구사항대로 agent-common = {admin, dev, test}, agent-core = {admin, dev} 충족.

### 4) 디렉토리 구조 + 권한(ACL 포함)

```text
$ ls -ld 주요 경로
drwxr-x---+ agent-admin agent-common  /home/agent-admin/agent-app
drwxrws---+ agent-admin agent-common  /home/agent-admin/agent-app/upload_files
drwxrws---+ agent-admin agent-core    /home/agent-admin/agent-app/api_keys
drwxrws---+ agent-admin agent-core    /home/agent-admin/agent-app/bin
drwxrws---+ agent-admin agent-core    /var/log/agent-app
-rw-r-----+ agent-admin agent-core    /home/agent-admin/agent-app/api_keys/t_secret.key
-rwxr-x---+ agent-dev   agent-core    /home/agent-admin/agent-app/bin/monitor.sh
```

핵심 정책 충족:
- `upload_files`: group=agent-common, R/W ✓
- `api_keys`, `/var/log/agent-app`: group=agent-core ONLY, R/W ✓ (others:--- 확인됨)
- `monitor.sh`: 소유자=agent-dev, 그룹=agent-core, 권한=750 ✓

ACL (요약 — 전체는 명령 출력 첨부):
```text
# upload_files
group:agent-common:rwx
default:group:agent-common:rwx
other::---

# api_keys
group:agent-core:rwx
default:group:agent-core:rwx
other::---

# /var/log/agent-app
group:agent-core:rwx
default:group:agent-core:rwx
other::---
```

setgid(2xxx) + ACL default 엔트리로 신규 파일/디렉토리에도 권한이 상속되도록 구성.

### 5) Boot Sequence 5단계 [OK] + "Agent READY"

```text
$ cd $AGENT_HOME && ./agent-app
>>> Starting Agent Boot Sequence...
[1/5] Checking User Account               [OK]
 ... Running as service user 'agent-admin' (uid=1000)
[2/5] Verifying Environment Variables     [OK]
 ... All required Envs correct
[3/5] Checking Required Files             [OK]
 ... Verified 'secret.key' with correct key string.
[4/5] Checking Port Availability          [OK]
 ... Port 15034 is available.
[5/5] Verifying Log Permission            [OK]
 ... Log directory is writable: /var/log/agent-app
------------------------------------------------------------
All Boot Checks Passed!
Agent READY

$ ss -tln 'sport = :15034'
LISTEN 0   1   0.0.0.0:15034   0.0.0.0:*
```

환경 변수(시스템 등록 `/etc/profile.d/agent-env.sh`):
```sh
export AGENT_HOME=/home/agent-admin/agent-app
export AGENT_PORT=15034
export AGENT_UPLOAD_DIR="$AGENT_HOME/upload_files"
export AGENT_KEY_PATH="$AGENT_HOME/api_keys/t_secret.key"
export AGENT_LOG_DIR=/var/log/agent-app
```

키 파일 내용(`$AGENT_KEY_PATH`): `agent_api_key_test` (1줄)

### 6) monitor.sh 실행 결과

```text
$ /home/agent-admin/agent-app/bin/monitor.sh
====== SYSTEM MONITOR RESULT ======

[HEALTH CHECK]
Checking process 'agent-app'... [OK] (PID: 4143)
Checking port 15034... [OK]
[INFO] ufw status check skipped (insufficient privilege)

[RESOURCE MONITORING]
CPU Usage : 100.0%
MEM Usage : 5.4%
DISK Used : 1%

[WARNING] CPU threshold exceeded (100.0% > 20%)

[INFO] Log appended: /var/log/agent-app/monitor.log
```

- 프로세스/포트 Health Check ✓
- CPU/MEM/DISK 자원 수집 ✓
- CPU > 20% 임계 경고 ✓
- monitor.log에 라인 추가 ✓

(주의: agent-app 자체가 CPU 부하를 생성하는 워크로드라 CPU 100%가 정상 동작이다.)

### 7) /var/log/agent-app/monitor.log 누적 기록

```text
$ wc -l /var/log/agent-app/monitor.log
3 /var/log/agent-app/monitor.log

$ tail -n 5 /var/log/agent-app/monitor.log
[2026-05-13 15:58:19] PID:4143 CPU:100.0% MEM:5.4% DISK_USED:1%
[2026-05-13 15:59:01] PID:4143 CPU:9.5%   MEM:5.0% DISK_USED:1%
[2026-05-13 16:00:02] PID:4143 CPU:100.0% MEM:4.8% DISK_USED:1%
```

라인 포맷 `[YYYY-MM-DD HH:MM:SS] PID:… CPU:..% MEM:..% DISK_USED:..%` 충족.

### 8) crontab 매분 실행 등록 및 1분 후 자동 누적 확인

```text
$ crontab -l   (as agent-admin)
AGENT_HOME=/home/agent-admin/agent-app
AGENT_PORT=15034
AGENT_LOG_DIR=/var/log/agent-app
* * * * * /home/agent-admin/agent-app/bin/monitor.sh >> /var/log/agent-app/monitor.cron.out 2>&1
```

자동 누적 증거 (등록 후 90초 대기):
- 등록 직후 수동 실행 1회 → `15:58:19` 라인.
- 첫 cron tick: `15:59:01` ← **자동 추가** (1분 내)
- 두 번째 tick: `16:00:02` ← **자동 추가**

cron 서비스 상태: `sudo systemctl enable --now cron` 완료.

---

## 로그 보존 정책 (monitor.sh 자체 구현)
PDF "monitor.log가 커지면 최대 10MB/10개 파일 유지" 요구는 monitor.sh 안에서 직접 구현:

```bash
MAX_BYTES=$((10 * 1024 * 1024))   # 10MB
MAX_FILES=10
if [ "$(stat -c %s "$LOG_FILE")" -ge "$MAX_BYTES" ]; then
  # monitor.log.9 제거 → .1→.2 … 으로 회전 → 현 로그를 .1 로
fi
```

logrotate 없이 스크립트 자체에서 처리하므로 cron 외부 의존이 없음.

---

## 학습 정리 (PDF 과제 목표 기준)
- **SSH 포트 변경 + Root 차단**: 기본 22번은 자동 스캔의 1차 표적이라 변경으로 노출 감소.
  Root 원격 접속 차단은 무차별 대입을 사용자 계정으로 한 단계 우회시켜 sudo 기반 감사를 강제.
- **UFW "필요 포트만 허용"**: default deny incoming + 명시 허용(20022, 15034)으로 공격 표면 최소화.
- **agent-common (공유) vs agent-core (보안)**: 업로드 파일은 QA(test)까지 협업 필요하지만 키와
  로그는 운영/개발 한정 → 그룹 분리 + ACL/setgid로 디렉토리 생성 시점에 권한이 자동 상속되어
  실수로 권한이 풀리는 사고를 막음.
- **환경 변수 고정 이유**: 앱이 가정하는 디렉토리/포트/키 경로를 코드 밖에서 일관 주입.
  `/etc/profile.d/agent-env.sh` 로 모든 셸에 동일 값 보장 + cron 에는 crontab 내 변수로 재주입
  (cron 환경 변수가 비어 있음을 가정해 monitor.sh 내부에서도 기본값 fallback).
- **monitor.sh 흐름**: Health Check(실패 시 즉시 exit 1) → 상태 점검(경고만) → 자원 수집 →
  임계 경고 → 로그 기록. 운영 문제 추적의 1차 데이터 라인.
- **crontab + 로그 보존**: 1분 단위로 시계열 데이터를 축적하지만 무한 증가 방지를 위해 10MB×10
  로테이션. 30일/7일 같은 시간 정책은 보너스 영역.

---

## 산출 파일
- `monitor.sh` — 본 디렉토리(`m1/monitor.sh`)에 동봉. 실행본은 머신 내 `$AGENT_HOME/bin/monitor.sh`.
- `Performance-Report.md` — 본 문서.
