# =============================================================
# 시스템 관제 자동화 실습 환경 - Dockerfile
# 베이스: ubuntu:24.04 (amd64)  /  실행 바이너리: agent-app-linux-x86
# 빌드 단계: 패키지 설치 · 계정/그룹/디렉토리/권한/ACL · 파일 복사
# 런타임 단계: entrypoint.sh (sshd/cron/ufw 기동, 앱 실행)
# =============================================================
FROM --platform=linux/amd64 ubuntu:24.04

# ── 1. 패키지 설치 ───────────────────────────────────────────
# openssh-server: SSH / ufw: 방화벽 / cron: 자동 실행
# procps: ps·free / iproute2: ss / acl: setfacl·getfacl / sudo: 권한 위임
RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        openssh-server ufw cron procps iproute2 acl sudo && \
    rm -rf /var/lib/apt/lists/*

# ── 2. 환경 변수 (PDF §4.3) ──────────────────────────────────
# 참고: 제공 바이너리는 AGENT_KEY_PATH 를 "키 디렉토리"로, 키 파일명을
#       'secret.key' 로 요구한다(PDF 예시 't_secret.key' 와 상이).
#       실행 대상 바이너리가 기준이므로 바이너리 사양을 따른다.
ENV AGENT_HOME=/home/agent-admin/agent-app \
    AGENT_PORT=15034 \
    AGENT_UPLOAD_DIR=/home/agent-admin/agent-app/upload_files \
    AGENT_KEY_PATH=/home/agent-admin/agent-app/api_keys \
    AGENT_LOG_DIR=/var/log/agent-app

# ── 3. 그룹/계정 생성 (PDF §4.2 - 역할 기반 + 최소 권한) ─────
# agent-common: admin,dev,test  /  agent-core: admin,dev
RUN groupadd agent-common && \
    groupadd agent-core && \
    useradd -m -s /bin/bash -u 1001 agent-admin && \
    useradd -m -s /bin/bash -u 1002 agent-dev && \
    useradd -m -s /bin/bash -u 1003 agent-test && \
    usermod -aG agent-common,agent-core agent-admin && \
    usermod -aG agent-common,agent-core agent-dev && \
    usermod -aG agent-common            agent-test

# ── 4. 디렉토리 구조 + 권한 + ACL (PDF §4.2 핵심 정책) ───────
# upload_files : group=agent-common, R/W   (setgid 2770)
# api_keys     : group=agent-core ONLY R/W (setgid 2770)
# /var/log/agent-app : group=agent-core ONLY R/W (setgid 2770)
# 기본 ACL(-d) 로 신규 파일이 그룹 rwx 권한을 상속하도록 설정
RUN mkdir -p "$AGENT_HOME/upload_files" \
             "$AGENT_HOME/api_keys" \
             "$AGENT_HOME/bin" \
             "$AGENT_LOG_DIR" && \
    chown agent-admin:agent-admin  "$AGENT_HOME" "$AGENT_HOME/bin" && \
    chown agent-admin:agent-common "$AGENT_HOME/upload_files" && \
    chown agent-admin:agent-core   "$AGENT_HOME/api_keys" && \
    chown agent-admin:agent-core   "$AGENT_LOG_DIR" && \
    chmod 2770 "$AGENT_HOME/upload_files" "$AGENT_HOME/api_keys" "$AGENT_LOG_DIR" && \
    setfacl -d -m g:agent-common:rwx "$AGENT_HOME/upload_files" && \
    setfacl -d -m g:agent-core:rwx   "$AGENT_HOME/api_keys" && \
    setfacl -d -m g:agent-core:rwx   "$AGENT_LOG_DIR"

# ── 5. 키 파일 생성 (1줄, 바이너리 요구 파일명 secret.key) ───
RUN echo 'agent_api_key_test' > "$AGENT_KEY_PATH/secret.key" && \
    chown agent-admin:agent-core "$AGENT_KEY_PATH/secret.key" && \
    chmod 660 "$AGENT_KEY_PATH/secret.key"

# ── 6. 애플리케이션 바이너리 복사 ────────────────────────────
COPY agent-app-linux-x86 "$AGENT_HOME/agent-app-linux-x86"
RUN chown agent-admin:agent-core "$AGENT_HOME/agent-app-linux-x86" && \
    chmod 750 "$AGENT_HOME/agent-app-linux-x86"

# ── 7. monitor.sh 복사 + 권한 (PDF §4.4 - agent-dev:agent-core 750) ─
COPY monitor.sh "$AGENT_HOME/bin/monitor.sh"
RUN chown agent-dev:agent-core "$AGENT_HOME/bin/monitor.sh" && \
    chmod 750 "$AGENT_HOME/bin/monitor.sh"

# ── 8. 검증 스크립트 복사 ────────────────────────────────────
COPY verify.sh /usr/local/bin/verify.sh
RUN chmod 755 /usr/local/bin/verify.sh

# ── 9. SSH 설정 (PDF §4.1 - 포트 20022, Root 로그인 차단) ────
RUN mkdir -p /run/sshd && \
    sed -i 's/^#\?Port .*/Port 20022/'                       /etc/ssh/sshd_config && \
    sed -i 's/^#\?PermitRootLogin .*/PermitRootLogin no/'     /etc/ssh/sshd_config

# ── 10. sudo 위임: agent-admin 이 ufw 상태만 무비번 조회 가능 ─
# monitor.sh 가 비루트(agent-admin/cron)로 방화벽 상태를 점검하기 위함
RUN echo 'agent-admin ALL=(root) NOPASSWD: /usr/sbin/ufw status' \
        > /etc/sudoers.d/agent-admin && \
    chmod 0440 /etc/sudoers.d/agent-admin

# ── 11. 런타임 진입점 ────────────────────────────────────────
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 755 /usr/local/bin/entrypoint.sh

# ── 12. 래퍼 스크립트 ────────────────────────────────────────
# docker run image                  → bash 쉘만 (entrypoint 미실행)
# docker run image start-entrypoint → entrypoint.sh 실행 (시스템 풀 기동)
COPY docker-wrapper.sh /usr/local/bin/docker-wrapper.sh
RUN chmod 755 /usr/local/bin/docker-wrapper.sh

EXPOSE 20022 15034
ENTRYPOINT ["/usr/local/bin/docker-wrapper.sh"]
CMD ["bash"]
