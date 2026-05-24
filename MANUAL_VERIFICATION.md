# 수동 검증 체크리스트

`verify.sh` 자동 검증과 동일한 8개 항목을 사람이 직접 명령어로 확인하는 절차다.
컨테이너 실행 후 아래 명령을 순서대로 입력하고 "기대 결과"와 대조한다.

## 준비

```bash
# 이미지 빌드
docker build -t agent-monitor output_시스템관제자동화스크립트개발_b1/

# 시스템 풀 기동 (start-entrypoint 커맨드 필수 — 미입력 시 bash 쉘만 뜸)
docker run -d --cap-add=NET_ADMIN --name am agent-monitor start-entrypoint

# 컨테이너 진입
docker exec -it am bash
```

---

## 1. SSH 포트 변경(20022) 및 Root 원격 접속 차단

```bash
grep -E '^(Port|PermitRootLogin)' /etc/ssh/sshd_config
ss -tlnp | grep sshd
```

**기대 결과**: `Port 20022`, `PermitRootLogin no` 출력. `ss` 결과에 `0.0.0.0:20022` LISTEN(sshd) 표시.

## 2. 방화벽(UFW) 활성화 및 허용 포트

```bash
ufw status
```

**기대 결과**: `Status: active`, 허용 목록에 `20022/tcp`, `15034/tcp` 만 존재.

## 3. 계정/그룹 생성 확인

```bash
id agent-admin
id agent-dev
id agent-test
getent group agent-common agent-core
```

**기대 결과**:
- `agent-admin`/`agent-dev` → `agent-common`, `agent-core` 그룹 포함
- `agent-test` → `agent-common` 만 포함
- `agent-common` 멤버 = admin,dev,test / `agent-core` 멤버 = admin,dev

## 4. 디렉토리 구조 및 권한(ACL 포함)

```bash
ls -ld /home/agent-admin/agent-app/upload_files \
       /home/agent-admin/agent-app/api_keys \
       /var/log/agent-app
getfacl /home/agent-admin/agent-app/api_keys
```

**기대 결과**:
- `upload_files` → 그룹 `agent-common`, 권한 `drwxrws---` (2770)
- `api_keys`, `/var/log/agent-app` → 그룹 `agent-core`, 권한 `drwxrws---` (2770)
- `getfacl` 출력에 `default:group:agent-core:rwx` 포함

## 5. monitor.sh 권한 / 키 파일

```bash
ls -l /home/agent-admin/agent-app/bin/monitor.sh
cat /home/agent-admin/agent-app/api_keys/secret.key
```

**기대 결과**: `monitor.sh` → `-rwxr-x---` 소유 `agent-dev agent-core`. 키 파일(`secret.key`) 내용 = `agent_api_key_test`.

## 6. 앱 Boot Sequence 및 포트 LISTEN

```bash
docker logs am          # (컨테이너 외부에서) Boot Sequence 확인
pgrep -af agent-app-linux-x86
ss -tln | grep 15034
```

**기대 결과**: 로그에 `[1/5]~[5/5] ... [OK]` 5단계와 `Agent READY` 출력. 프로세스 실행 중, `0.0.0.0:15034` LISTEN.

## 7. monitor.sh 실행 결과 / monitor.log 누적

```bash
# 수동 단발 실행 (agent-admin 계정)
su agent-admin -c /home/agent-admin/agent-app/bin/monitor.sh

# cron 자동 누적 확인 - 1분 간격 증가
wc -l /var/log/agent-app/monitor.log
sleep 65
wc -l /var/log/agent-app/monitor.log     # 줄 수가 증가해야 함
tail -n 3 /var/log/agent-app/monitor.log
```

**기대 결과**:
- 수동 실행 시 `[HEALTH CHECK] [OK]`, 자원 수치, `[INFO] Log appended` 출력
- `sleep` 전후 줄 수 증가
- 로그 라인 형식 `[YYYY-MM-DD HH:MM:SS] PID:... CPU:..% MEM:..% DISK_USED:..%`

## 8. crontab 매분 실행 등록

```bash
crontab -u agent-admin -l
```

**기대 결과**: `* * * * * /home/agent-admin/agent-app/bin/monitor.sh ...` 라인 출력.

---

## 일괄 자동 검증

위 항목을 한 번에 점검하려면:

```bash
docker exec am verify.sh
```

`PASS=N FAIL=0` 이면 전체 통과.
