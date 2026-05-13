#!/usr/bin/env bash
# monitor.sh - 시스템 관제 자동화 스크립트
# 소유자: agent-dev, 그룹: agent-core, 권한: 750
# 실행: agent-admin (cron) 또는 agent-core 그룹 멤버

set -u -o pipefail

# cron 환경 대비: PATH와 AGENT_* 기본값 보장
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
: "${AGENT_HOME:=/home/agent-admin/agent-app}"
: "${AGENT_PORT:=15034}"
: "${AGENT_LOG_DIR:=/var/log/agent-app}"

APP_NAME="agent-app"
LOG_FILE="$AGENT_LOG_DIR/monitor.log"
MAX_BYTES=$((10 * 1024 * 1024))   # 10MB
MAX_FILES=10                      # monitor.log + .1 ~ .9

ts() { date '+%Y-%m-%d %H:%M:%S'; }

echo "====== SYSTEM MONITOR RESULT ======"
echo
echo "[HEALTH CHECK]"

# 프로세스 확인
APP_PID="$(pgrep -x "$APP_NAME" | head -n1 || true)"
if [ -z "$APP_PID" ]; then
  echo "Checking process '$APP_NAME'... [FAIL] (process not running)"
  exit 1
fi
echo "Checking process '$APP_NAME'... [OK] (PID: $APP_PID)"

# 포트 LISTEN 확인
if ! ss -tln "sport = :$AGENT_PORT" | grep -q LISTEN; then
  echo "Checking port $AGENT_PORT... [FAIL] (not listening)"
  exit 1
fi
echo "Checking port $AGENT_PORT... [OK]"

# 방화벽 활성 상태 (경고만)
if command -v ufw >/dev/null 2>&1; then
  if ! sudo -n ufw status 2>/dev/null | grep -q '^Status: active' \
     && ! ufw status 2>/dev/null | grep -q '^Status: active'; then
    # ufw status는 root 권한 필요. 일반 사용자는 확인 불가하므로 경고 생략 가능하나
    # 명시적으로 [INFO] 로 남긴다.
    echo "[INFO] ufw status check skipped (insufficient privilege)"
  fi
fi

echo
echo "[RESOURCE MONITORING]"

# CPU: top 두 번째 샘플에서 100 - %idle
CPU_PCT="$(top -bn2 -d 0.3 | awk '/^%Cpu/{c=100-$8} END{printf "%.1f", c}')"
# MEM: used/total * 100
MEM_PCT="$(free | awk '/^Mem:/ {printf "%.1f", $3/$2*100}')"
# DISK: root partition used %
DISK_PCT="$(df -P / | awk 'NR==2 {gsub("%","",$5); print $5}')"

echo "CPU Usage : ${CPU_PCT}%"
echo "MEM Usage : ${MEM_PCT}%"
echo "DISK Used : ${DISK_PCT}%"
echo

# 임계 경고
awk -v v="$CPU_PCT"  'BEGIN{exit !(v+0>20)}' && \
  echo "[WARNING] CPU threshold exceeded (${CPU_PCT}% > 20%)"
awk -v v="$MEM_PCT"  'BEGIN{exit !(v+0>10)}' && \
  echo "[WARNING] MEM threshold exceeded (${MEM_PCT}% > 10%)"
awk -v v="$DISK_PCT" 'BEGIN{exit !(v+0>80)}' && \
  echo "[WARNING] DISK threshold exceeded (${DISK_PCT}% > 80%)"

# 로그 디렉토리 보장
if [ ! -d "$AGENT_LOG_DIR" ]; then
  echo "[ERROR] log directory missing: $AGENT_LOG_DIR" >&2
  exit 1
fi

# 로그 로테이션: monitor.log 가 10MB 초과 시 .1 ~ .9 로 회전, .9 초과 시 제거
if [ -f "$LOG_FILE" ]; then
  size="$(stat -c %s "$LOG_FILE" 2>/dev/null || echo 0)"
  if [ "$size" -ge "$MAX_BYTES" ]; then
    i=$((MAX_FILES - 1))
    [ -f "$LOG_FILE.$i" ] && rm -f "$LOG_FILE.$i"
    while [ "$i" -gt 1 ]; do
      prev=$((i-1))
      [ -f "$LOG_FILE.$prev" ] && mv "$LOG_FILE.$prev" "$LOG_FILE.$i"
      i=$prev
    done
    mv "$LOG_FILE" "$LOG_FILE.1"
  fi
fi

# 로그 라인 기록
printf '[%s] PID:%s CPU:%s%% MEM:%s%% DISK_USED:%s%%\n' \
  "$(ts)" "$APP_PID" "$CPU_PCT" "$MEM_PCT" "$DISK_PCT" >> "$LOG_FILE"

echo
echo "[INFO] Log appended: $LOG_FILE"
exit 0
