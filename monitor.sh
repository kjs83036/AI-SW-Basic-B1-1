#!/usr/bin/env bash
# =============================================================
# monitor.sh - 시스템 관제 자동화 스크립트
# 역할: 앱 헬스체크 / 시스템 자원 수집 / 임계값 경고 / 로그 기록·로테이션
# 제약: Bash 전용 (PDF 제약사항 - Python 등 대체 금지)
# 실행: agent-admin 계정의 crontab 으로 매분 자동 실행
# =============================================================
set -u

# ── 설정값 (환경 변수 미지정 시 기본값 사용) ──────────────────
APP_NAME="agent-app-linux-x86"          # 점검 대상 프로세스명
APP_PORT="${AGENT_PORT:-15034}"          # 점검 대상 포트
LOG_DIR="${AGENT_LOG_DIR:-/var/log/agent-app}"
LOG_FILE="${LOG_DIR}/monitor.log"
MAX_SIZE=$((10 * 1024 * 1024))           # 로그 회전 기준 10MB
MAX_FILES=10                             # 보관 최대 파일 수

CPU_THRESHOLD=20                         # CPU 경고 임계값(%)
MEM_THRESHOLD=10                         # MEM 경고 임계값(%)
DISK_THRESHOLD=80                        # DISK 경고 임계값(%)

echo "====== SYSTEM MONITOR RESULT ======"
echo

# ── 1. Health Check (실패 시 즉시 종료) ──────────────────────
echo "[HEALTH CHECK]"
APP_PID=$(pgrep -f "$APP_NAME" | head -n1)
if [ -n "$APP_PID" ]; then
    echo "Checking process '$APP_NAME'... [OK] (PID: $APP_PID)"
else
    echo "Checking process '$APP_NAME'... [FAIL]"
    echo "[ERROR] 애플리케이션 프로세스가 실행 중이 아닙니다."
    exit 1
fi

if ss -ltn 2>/dev/null | grep -qE ":${APP_PORT}([^0-9]|$)"; then
    echo "Checking port ${APP_PORT}... [OK]"
else
    echo "Checking port ${APP_PORT}... [FAIL]"
    echo "[ERROR] 포트 ${APP_PORT} 가 LISTEN 상태가 아닙니다."
    exit 1
fi
echo

# ── 2. 상태 점검 (경고만 출력, 종료하지 않음) ────────────────
echo "[STATUS CHECK]"
if sudo -n ufw status 2>/dev/null | grep -q "Status: active"; then
    echo "Firewall (UFW)... [OK] active"
else
    echo "[WARNING] 방화벽(UFW)이 비활성 상태입니다."
fi
echo

# ── 3. 시스템 자원 수집 ──────────────────────────────────────
# CPU: /proc/stat 를 1초 간격으로 두 번 읽어 사용률 델타 계산
read -r _ u1 n1 s1 i1 w1 _ < /proc/stat
sleep 1
read -r _ u2 n2 s2 i2 w2 _ < /proc/stat
busy_delta=$(( (u2+n2+s2) - (u1+n1+s1) ))
total_delta=$(( (u2+n2+s2+i2+w2) - (u1+n1+s1+i1+w1) ))
CPU=$(awk -v b="$busy_delta" -v t="$total_delta" \
      'BEGIN { printf "%.1f", (t>0) ? b/t*100 : 0 }')

# MEM: free 출력에서 사용 메모리 / 전체 메모리 비율
MEM=$(free | awk '/^Mem:/ { printf "%.1f", $3/$2*100 }')

# DISK: root 파티션 사용률(Used %)
DISK=$(df / | awk 'NR==2 { gsub(/%/,"",$5); print $5 }')

echo "[RESOURCE MONITORING]"
echo "CPU Usage : ${CPU}%"
echo "MEM Usage : ${MEM}%"
echo "DISK Used : ${DISK}%"
echo

# ── 4. 임계값 경고 (경고만 출력) ─────────────────────────────
awk -v v="$CPU" -v t="$CPU_THRESHOLD" 'BEGIN { exit !(v>t) }' \
    && echo "[WARNING] CPU threshold exceeded (${CPU}% > ${CPU_THRESHOLD}%)"
awk -v v="$MEM" -v t="$MEM_THRESHOLD" 'BEGIN { exit !(v>t) }' \
    && echo "[WARNING] MEM threshold exceeded (${MEM}% > ${MEM_THRESHOLD}%)"
awk -v v="$DISK" -v t="$DISK_THRESHOLD" 'BEGIN { exit !(v>t) }' \
    && echo "[WARNING] DISK threshold exceeded (${DISK}% > ${DISK_THRESHOLD}%)"
echo

# ── 5. 로그 로테이션 (기록 직전 용량 점검) ───────────────────
# monitor.log 가 10MB 초과 시: .9 삭제 → .8→.9 … .1→.2 → 본파일→.1
# 결과적으로 본파일 + .1~.9 = 최대 10개 유지
rotate_log() {
    [ -f "$LOG_FILE" ] || return 0
    local size
    size=$(stat -c %s "$LOG_FILE" 2>/dev/null || echo 0)
    [ "$size" -lt "$MAX_SIZE" ] && return 0

    local i
    for (( i = MAX_FILES - 1; i >= 1; i-- )); do
        if [ -f "${LOG_FILE}.${i}" ]; then
            if [ "$i" -ge $((MAX_FILES - 1)) ]; then
                rm -f "${LOG_FILE}.${i}"            # 가장 오래된 파일 삭제
            else
                mv "${LOG_FILE}.${i}" "${LOG_FILE}.$((i+1))"
            fi
        fi
    done
    mv "$LOG_FILE" "${LOG_FILE}.1"
}

# ── 6. 로그 기록 ─────────────────────────────────────────────
mkdir -p "$LOG_DIR" 2>/dev/null
rotate_log
TS=$(date '+%Y-%m-%d %H:%M:%S')
echo "[${TS}] PID:${APP_PID} CPU:${CPU}% MEM:${MEM}% DISK_USED:${DISK}%" >> "$LOG_FILE"
echo "[INFO] Log appended: $LOG_FILE"
