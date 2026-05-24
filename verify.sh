#!/usr/bin/env bash
# =============================================================
# verify.sh - 요구사항 수행 내역 자동 검증 스크립트
# PDF "필수 증거 자료 체크리스트" 8개 항목을 자동 점검한다.
# 컨테이너 내부에서 root 로 실행 (docker exec <컨테이너> verify.sh).
# =============================================================
set -u

AGENT_HOME="${AGENT_HOME:-/home/agent-admin/agent-app}"
AGENT_LOG_DIR="${AGENT_LOG_DIR:-/var/log/agent-app}"
KEY_FILE="${AGENT_KEY_PATH:-$AGENT_HOME/api_keys}/secret.key"

PASS=0
FAIL=0

# 항목 결과 출력 헬퍼: pass <메시지> / fail <메시지>
pass() { echo "  [PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }
# 조건(첫 인자 종료코드)에 따라 pass/fail 기록
check() { if [ "$1" -eq 0 ]; then pass "$2"; else fail "$3"; fi; }

echo "================================================================"
echo " 시스템 관제 자동화 - 자동 검증 결과"
echo "================================================================"

# ── 1. SSH 포트 변경(20022) 및 Root 원격 접속 차단 ───────────
echo "[1] SSH 보안 설정"
grep -qE '^Port 20022'              /etc/ssh/sshd_config \
    && pass "sshd_config Port 20022" || fail "SSH 포트가 20022 가 아님"
grep -qE '^PermitRootLogin no'      /etc/ssh/sshd_config \
    && pass "sshd_config PermitRootLogin no" || fail "Root 로그인 미차단"
ss -tlnp 2>/dev/null | grep -q ':20022 ' \
    && pass "포트 20022 LISTEN (sshd)" || fail "20022 미LISTEN"

# ── 2. 방화벽(UFW) 활성화 및 허용 포트 ───────────────────────
echo "[2] 방화벽(UFW) 설정"
UFW_OUT=$(ufw status 2>/dev/null)
echo "$UFW_OUT" | grep -q 'Status: active' \
    && pass "UFW active" || fail "UFW 비활성"
echo "$UFW_OUT" | grep -q '20022/tcp' \
    && pass "20022/tcp 허용" || fail "20022/tcp 미허용"
echo "$UFW_OUT" | grep -q '15034/tcp' \
    && pass "15034/tcp 허용" || fail "15034/tcp 미허용"

# ── 3. 계정/그룹 생성 ────────────────────────────────────────
echo "[3] 계정/그룹 체계"
for u in agent-admin agent-dev agent-test; do
    id "$u" >/dev/null 2>&1 && pass "계정 $u 존재" || fail "계정 $u 없음"
done
# agent-common: admin,dev,test  /  agent-core: admin,dev
COMMON=$(getent group agent-common | awk -F: '{print $4}')
CORE=$(getent group agent-core   | awk -F: '{print $4}')
[[ "$COMMON" == *agent-admin* && "$COMMON" == *agent-dev* && "$COMMON" == *agent-test* ]] \
    && pass "agent-common = admin,dev,test" || fail "agent-common 멤버 불일치 ($COMMON)"
[[ "$CORE" == *agent-admin* && "$CORE" == *agent-dev* ]] \
    && pass "agent-core = admin,dev" || fail "agent-core 멤버 불일치 ($CORE)"

# ── 4. 디렉토리 구조 및 권한(ACL 포함) ───────────────────────
echo "[4] 디렉토리 권한"
chk_dir() {  # $1=경로 $2=기대그룹 $3=기대권한
    local g p
    g=$(stat -c '%G' "$1" 2>/dev/null)
    p=$(stat -c '%a' "$1" 2>/dev/null)
    if [ "$g" = "$2" ] && [ "$p" = "$3" ]; then
        pass "$1 ($g $p)"
    else
        fail "$1 권한 불일치 (그룹=$g 권한=$p, 기대=$2 $3)"
    fi
}
chk_dir "$AGENT_HOME/upload_files" agent-common 2770
chk_dir "$AGENT_HOME/api_keys"     agent-core   2770
chk_dir "$AGENT_LOG_DIR"           agent-core   2770
getfacl "$AGENT_HOME/upload_files" 2>/dev/null | grep -q 'default:group:agent-common:rwx' \
    && pass "upload_files 기본 ACL(agent-common rwx)" || fail "upload_files 기본 ACL 없음"
getfacl "$AGENT_HOME/api_keys" 2>/dev/null | grep -q 'default:group:agent-core:rwx' \
    && pass "api_keys 기본 ACL(agent-core rwx)" || fail "api_keys 기본 ACL 없음"

# ── 5. monitor.sh 권한 + 키 파일 ─────────────────────────────
echo "[5] monitor.sh / 키 파일"
MS="$AGENT_HOME/bin/monitor.sh"
[ "$(stat -c '%U:%G %a' "$MS" 2>/dev/null)" = "agent-dev:agent-core 750" ] \
    && pass "monitor.sh = agent-dev:agent-core 750" \
    || fail "monitor.sh 권한 불일치 ($(stat -c '%U:%G %a' "$MS" 2>/dev/null))"
[ "$(cat "$KEY_FILE" 2>/dev/null)" = "agent_api_key_test" ] \
    && pass "키 파일(secret.key) 내용 일치" || fail "키 파일 내용 불일치"

# ── 6. 앱 Boot / 포트 LISTEN ─────────────────────────────────
echo "[6] 애플리케이션 상태"
pgrep -f agent-app-linux-x86 >/dev/null \
    && pass "agent-app 프로세스 실행 중" || fail "agent-app 미실행"
ss -tln 2>/dev/null | grep -qE ':15034([^0-9]|$)' \
    && pass "포트 15034 LISTEN" || fail "15034 미LISTEN"

# ── 7. monitor.log 누적 (cron 자동 실행 증거) ────────────────
echo "[7] monitor.log 누적"
LOG="$AGENT_LOG_DIR/monitor.log"
if [ -s "$LOG" ]; then
    LINES=$(wc -l < "$LOG")
    LAST=$(tail -n1 "$LOG")
    # 마지막 기록 시각이 최근 120초 이내면 cron 이 동작 중인 것으로 판정
    LTS=$(echo "$LAST" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}')
    if [ -n "$LTS" ]; then
        DIFF=$(( $(date +%s) - $(date -d "$LTS" +%s) ))
        check "$([ "$DIFF" -le 120 ] && echo 0 || echo 1)" \
              "monitor.log 최근 기록 (${LINES}줄, ${DIFF}초 전)" \
              "monitor.log 기록이 오래됨 (${DIFF}초 전) - cron 확인 필요"
    else
        fail "monitor.log 타임스탬프 파싱 실패"
    fi
else
    fail "monitor.log 가 비어있음 (cron 1~2분 대기 후 재검증)"
fi

# ── 8. crontab 등록 ──────────────────────────────────────────
echo "[8] cron 자동 실행 등록"
crontab -u agent-admin -l 2>/dev/null | grep -q 'monitor.sh' \
    && pass "agent-admin crontab 에 monitor.sh 등록됨" \
    || fail "crontab 미등록"

# ── 결과 요약 ────────────────────────────────────────────────
echo "================================================================"
echo " 검증 결과: PASS=$PASS  FAIL=$FAIL"
echo "================================================================"
[ "$FAIL" -eq 0 ] && { echo " 전체 항목 통과"; exit 0; } \
                  || { echo " 실패 항목 존재 - 위 [FAIL] 확인"; exit 1; }
