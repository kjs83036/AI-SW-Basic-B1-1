#!/usr/bin/env bash
# =============================================================
# docker-wrapper.sh - 컨테이너 진입점 래퍼
# 사용법:
#   docker run image                  → bash 쉘 (entrypoint 미실행)
#   docker run image start-entrypoint → entrypoint.sh 실행
#   docker run image <임의 명령>      → 해당 명령 실행
# =============================================================
if [ "$1" = "start-entrypoint" ]; then
    exec /usr/local/bin/entrypoint.sh
else
    exec "$@"
fi
