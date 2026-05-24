# 통합 설명

## 과제 요약

리눅스 다중 사용자 환경에서 권한 관리·네트워크 보안을 구성하고, 애플리케이션 배포
환경을 구축한 뒤 시스템 상태를 수집·기록하는 관제 자동화를 구현하는 과제다. SSH
보안(포트 20022·Root 차단), UFW 방화벽(필요 포트만 허용), 역할 기반 계정/그룹/ACL,
환경 변수 기반 앱 실행, `monitor.sh` 관제 스크립트, cron 매분 자동 실행이 핵심이다.
사용자 추가 요구로 환경 구성을 **Dockerfile**로 코드화하고, 검증을 **자동(verify.sh)**과
**수동(MANUAL_VERIFICATION.md)** 두 방식으로 제공한다.

## 선택과제 처리

선택과제 미수행. (PDF 명시 항목: 보너스 1 — `report.sh` 요약 리포트, 보너스 2 — 시간
기반 로그 보존 정책(7일 압축/30일 삭제). 본 산출물은 필수 요구사항만 구현한다.)

## 바이너리 사양과 PDF 표기 차이 (중요)

제공 바이너리(`agent-app-linux-x86`)를 실제 실행해 확인한 결과, PDF 예시 표기와 다음
차이가 있었다. PDF §7 "제공된 앱은 실행 대상" 규정에 따라 **바이너리 사양을 따랐다**.

| 항목 | PDF 예시 | 실제 바이너리 요구 | 적용 |
|------|----------|--------------------|------|
| `AGENT_KEY_PATH` | 키 파일 경로 (`.../t_secret.key`) | 키 **디렉토리** 경로 (`.../api_keys`) | 디렉토리로 설정 |
| 키 파일명 | `t_secret.key` | `secret.key` | `secret.key` 생성 |

키 파일 내용(`agent_api_key_test`)은 PDF와 동일하며, 바이너리가 `Verified 'secret.key'
with correct key string` 으로 검증 통과를 확인했다.

## 파일별 설명

### Dockerfile

#### 전체 설계 의도
환경 구성을 단계별 `RUN` 레이어로 코드화해 재현 가능하게 만들었다. "빌드 시 결정
가능한 것"(패키지·계정·디렉토리·권한·파일 복사·sshd 설정)은 모두 빌드 단계에 두고,
"실행 중에만 가능한 것"(데몬 기동·방화벽·cron 등록·앱 실행)은 `entrypoint.sh`로 분리했다.
별도 `setup.sh`를 두지 않은 이유: Dockerfile 자체가 설치·복사·권한변경 명세이므로
중복이다.

실제 `ENTRYPOINT`는 `docker-wrapper.sh`이며 `CMD ["bash"]`를 기본값으로 가진다.
`start-entrypoint` 커맨드 입력 시에만 `entrypoint.sh`로 분기하고, 그 외에는 전달된
인자를 그대로 `exec`한다. 이 구조로 `docker run image`는 bash 쉘만 열리고,
시스템 풀 기동은 명시적 커맨드(`start-entrypoint`)로만 실행된다.

#### 단계별 설계 근거
- **베이스 `ubuntu:24.04` (amd64)**: 신규 제공 바이너리 `agent-app-linux-x86`이 x86-64
  ELF이므로 amd64 베이스를 선택. PDF 권장 Ubuntu 22.04 대신 사용자 지정 24.04 적용.
- **계정/그룹**: `agent-common`(admin,dev,test), `agent-core`(admin,dev)를 supplementary
  그룹으로 부여. agent-admin이 agent-core에 속해야 cron으로 monitor.sh 실행 및 로그
  쓰기가 가능 — PDF §4.4 요건.
- **`2770` + setgid**: 디렉토리 내 신규 파일이 디렉토리 그룹을 상속하도록 setgid 비트
  부여. `others`에 0을 줘 "보안 디렉토리"(api_keys/log)를 agent-core 외 접근 차단.
- **기본 ACL(`setfacl -d`)**: PDF "권한(ACL 포함)" 요건 충족. setgid는 그룹 소유만
  상속시키므로, rwx 권한까지 신규 파일에 상속시키려면 기본 ACL이 필요 — 대안으로
  umask 조정도 가능하나 디렉토리 단위로 명시적인 ACL이 검증·추적에 유리해 채택.
- **sudoers 위임**: monitor.sh가 비루트로 UFW 상태를 점검해야 하므로 `ufw status`
  한 명령만 NOPASSWD로 위임. PDF §7 "필요한 경우에만 sudo" 원칙에 맞춰 최소 범위.

### docker-wrapper.sh

#### 전체 설계 의도
`ENTRYPOINT`를 직접 `entrypoint.sh`에 연결하면 `docker run image`만으로 즉시 시스템이
풀 기동된다. 의도치 않은 자동 실행을 막기 위해 래퍼 스크립트를 사이에 두고, 트리거
커맨드(`start-entrypoint`)가 있을 때만 `entrypoint.sh`로 분기한다. 그 외 커맨드는
`exec "$@"`로 그대로 넘겨 `bash`, `ls` 등 임의 명령도 정상 동작한다.

```
docker run image                   → CMD["bash"] → bash 쉘
docker run image start-entrypoint  → entrypoint.sh 실행
docker run image <기타 명령>       → exec <기타 명령>
```

### entrypoint.sh

#### 전체 설계 의도
컨테이너에는 systemd가 없어 데몬을 직접 기동해야 한다. 4단계(sshd→cron→ufw→crontab)
준비 후 앱을 `exec`로 PID 1에 올려 컨테이너 수명을 앱과 일치시킨다.

#### 주요 결정
- **UFW 실패 허용**: 컨테이너에서 UFW는 `NET_ADMIN` 권한이 필요하다. 권한이 없어도
  앱 실행은 막지 않도록 `|| WARNING` 처리 — 방화벽은 PDF상 monitor.sh에서도 "경고만"
  하는 항목이므로 치명적 실패로 보지 않는다.
- **`su agent-admin -c`로 앱 실행**: PDF §4.3 "루트 실행 금지". 환경 변수를 `-c`
  문자열에 명시적으로 export해 전달 — `su`가 환경을 초기화하므로 누락 방지.
- **crontab 등록**: `* * * * *` 매분. cron은 Docker ENV를 상속하지 않으므로
  monitor.sh가 자체 기본값을 갖도록 설계(아래 참고).

### monitor.sh

#### 전체 설계 의도
Bash 전용 제약(PDF §7) 하에 외부 의존 없이 동작하도록 작성. cron 환경에서는 Docker
ENV가 전달되지 않으므로 모든 설정값에 `${VAR:-기본값}` 형태의 기본값을 부여했다.

#### 함수/블록별 설명

- **Health Check**: `pgrep -f`로 프로세스, `ss -ltn`으로 포트 15034 LISTEN 확인.
  둘 중 하나라도 실패 시 `exit 1` — PDF §4.4 "실패 시 종료" 요건. `ss`를 쓴 이유는
  `netstat`이 최신 배포판 기본 미설치이기 때문.
- **상태 점검(UFW)**: `sudo -n ufw status`로 점검. 비활성 시 `[WARNING]`만 출력하고
  종료하지 않음 — PDF §4.4 "비활성이면 WARNING, 종료 안 함" 명시 요건.
- **자원 수집 — CPU**: `/proc/stat`를 1초 간격 두 번 읽어 busy/total 델타로 계산.
  대안으로 `top -bn1`이 있으나 첫 샘플이 부팅 이후 누적값이라 부정확해 기각.
- **자원 수집 — MEM/DISK**: `free`의 used/total 비율, `df /`의 Used%. 단순·정확.
- **임계값 경고**: CPU/MEM이 소수점이라 Bash 정수 비교 불가 → `awk`로 float 비교.
  초과 시 `[WARNING]`만 출력(종료 안 함) — PDF §4.4 "경고만 출력".
- **`rotate_log()`**: 기록 직전 `stat`로 크기 확인, 10MB 초과 시 `.9` 삭제→`.8→.9`
  …→본파일→`.1`로 시프트. 본파일 + `.1~.9` = 최대 10개 유지. PDF §4.4 "10MB/10개"
  요건. 대안 `logrotate`도 가능하나 별도 데몬·설정 파일이 필요해, 자기완결적 스크립트
  로직을 채택(PDF가 "방법 자유"로 허용).
- **로그 기록**: `[YYYY-MM-DD HH:MM:SS] PID:.. CPU:..% MEM:..% DISK_USED:..%` 형식 —
  PDF §4.4 로그 포맷 그대로.

### verify.sh

#### 전체 설계 의도
PDF "필수 증거 자료 체크리스트" 8개 항목을 자동 점검한다. 항목별 `[PASS]/[FAIL]`을
출력하고 누계를 집계, FAIL이 하나라도 있으면 `exit 1` — CI/재실행 검증에 적합.

#### 주요 결정
- **`pass`/`fail`/`check` 헬퍼**: 21개 점검의 출력·집계를 일관되게 처리하기 위한
  최소 헬퍼. 추상화 과잉을 피해 3개 함수로 한정.
- **monitor.log 누적 판정**: "줄 수 증가"를 단발 실행으로 증명하기 어려워, 마지막
  기록 시각이 120초 이내인지로 cron 동작을 판정. 엄밀한 sleep-후-재집계 방식은
  MANUAL_VERIFICATION.md에 수동 절차로 안내.

### MANUAL_VERIFICATION.md
verify.sh와 동일 8항목을 사람이 직접 명령어로 확인하는 절차서. 각 항목에 실행 명령과
기대 결과를 명시. 자동 검증이 놓칠 수 있는 실제 출력 형태(`ufw status`, `getfacl`,
`ss -tlnp` 등)를 눈으로 대조하는 용도.

## 제약-코드 매핑 표

| PDF 제약/요구 | 충족 위치 |
|---------------|-----------|
| SSH 포트 20022 | Dockerfile §9 `sed ... Port 20022` |
| Root 원격 로그인 차단 | Dockerfile §9 `PermitRootLogin no` |
| 방화벽 UFW 활성화 | entrypoint.sh `ufw --force enable` |
| 20022·15034만 인바운드 허용 | entrypoint.sh `ufw allow 20022/tcp`·`15034/tcp` |
| 계정 agent-admin/dev/test | Dockerfile §3 `useradd` |
| 그룹 agent-common/agent-core | Dockerfile §3 `groupadd`+`usermod -aG` |
| 디렉토리 구조(AGENT_HOME 기준) | Dockerfile §4 `mkdir -p` |
| upload_files=agent-common R/W | Dockerfile §4 `chown :agent-common`+`chmod 2770` |
| api_keys·log=agent-core ONLY R/W | Dockerfile §4 `chown :agent-core`+`chmod 2770` |
| 권한 ACL 포함 | Dockerfile §4 `setfacl -d -m g:...:rwx` |
| 환경 변수(AGENT_HOME 등) | Dockerfile §2 `ENV` |
| 키 파일 생성(내용 1줄) | Dockerfile §5 `echo > .../secret.key` |
| 일반 계정 실행(루트 금지) | entrypoint.sh `su agent-admin -c` |
| monitor.sh 경로 $AGENT_HOME/bin | Dockerfile §7 `COPY ... /bin/monitor.sh` |
| monitor.sh 소유 agent-dev:agent-core 750 | Dockerfile §7 `chown`+`chmod 750` |
| Health Check 실패 시 exit 1 | monitor.sh 1번 블록 |
| UFW 비활성 시 WARNING(종료 안 함) | monitor.sh 2번 블록 |
| 자원 CPU/MEM/DISK 수집 | monitor.sh 3번 블록 |
| 임계값 CPU>20·MEM>10·DISK>80 | monitor.sh 4번 블록 |
| 로그 포맷·파일 경로 | monitor.sh 6번 블록 |
| 로그 10MB/10개 관리 | monitor.sh `rotate_log()` |
| cron 매분 실행(agent-admin) | entrypoint.sh `crontab -u agent-admin` |
| 자동화 스크립트 Bash 전용 | monitor.sh·entrypoint.sh·verify.sh·docker-wrapper.sh 전부 `#!/usr/bin/env bash` |

## 검증 결과

`docker build` → `docker run --cap-add=NET_ADMIN ... start-entrypoint` 후 실측:

- **앱 부팅**: Boot Sequence `[1/5]~[5/5]` 전부 `[OK]`, `All Boot Checks Passed!` /
  `Agent READY` 출력, 포트 15034 LISTEN 확인.
- **monitor.sh 수동 실행**: `[HEALTH CHECK] [OK]`, 자원 수치 출력, `monitor.log` 기록.
- **cron 자동 누적**: 매분 `monitor.log`에 라인 증가 확인.
  ```
  [2026-05-21 17:02:43] PID:1 CPU:1.3% MEM:6.5% DISK_USED:3%
  [2026-05-21 17:03:04] PID:1 CPU:0.7% MEM:6.9% DISK_USED:3%
  [2026-05-21 17:04:04] PID:1 CPU:1.4% MEM:5.7% DISK_USED:3%
  ```
- **verify.sh 자동 검증**: 8개 항목 21개 점검 전부 `[PASS]`, `PASS=21 FAIL=0`.
