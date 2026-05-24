#!/usr/bin/env bash
# =============================================================
# entrypoint.sh - 컨테이너 런타임 진입점
# 빌드 단계에서 할 수 없는 "데몬 기동/방화벽/cron 등록"을 수행한 뒤
# agent-app 을 비루트(agent-admin)로 포그라운드 실행한다.
# =============================================================
set -u

echo ">> [1/4] SSH 데몬 기동 (포트 20022)"
mkdir -p /run/sshd
/usr/sbin/sshd

echo ">> [2/4] cron 데몬 기동"
cron

echo ">> [3/4] UFW 방화벽 설정 (20022/tcp, 15034/tcp 만 허용)"
# 컨테이너에서 ufw 는 NET_ADMIN 권한이 필요하다.
# 권한이 없으면 경고만 남기고 계속 진행한다(앱 실행을 막지 않음).
if ufw --force enable 2>/dev/null; then
    ufw allow 20022/tcp
    ufw allow 15034/tcp
    echo "   UFW 활성화 완료"
else
    echo "   [WARNING] UFW 활성화 실패 - 컨테이너 실행 시 --cap-add=NET_ADMIN 필요"
fi

echo ">> [4/4] agent-admin crontab 등록 (monitor.sh 매분 실행)"
echo "* * * * * ${AGENT_HOME}/bin/monitor.sh >> ${AGENT_LOG_DIR}/cron.log 2>&1" \
    | crontab -u agent-admin -

echo ">> Boot 준비 완료 - agent-app 실행 (계정: agent-admin)"
echo "-------------------------------------------------------------"

# 환경 변수를 명시적으로 전달하며 비루트 계정으로 앱 실행.
# exec 로 PID 1 을 대체해 컨테이너 수명을 앱과 일치시킨다.
exec su agent-admin -c "
    export AGENT_HOME='${AGENT_HOME}'
    export AGENT_PORT='${AGENT_PORT}'
    export AGENT_UPLOAD_DIR='${AGENT_UPLOAD_DIR}'
    export AGENT_KEY_PATH='${AGENT_KEY_PATH}'
    export AGENT_LOG_DIR='${AGENT_LOG_DIR}'
    cd '${AGENT_HOME}'
    exec ./agent-app-linux-x86
"
