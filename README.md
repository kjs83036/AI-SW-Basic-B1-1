# 시스템 관제 자동화 스크립트 개발

## 개요

리눅스 서버 운영 환경(SSH 보안, UFW 방화벽, 역할 기반 계정/그룹/ACL, 앱 실행환경)을
구축하고, 시스템 상태를 주기적으로 수집·기록하는 관제 자동화를 구현한 산출물이다. 환경
구성은 **Dockerfile**로 코드화했으며, 관제 스크립트 `monitor.sh`는 cron으로 매분 자동
실행된다. 수행 결과는 **자동(verify.sh)**·**수동(MANUAL_VERIFICATION.md)** 두 방식으로
검증한다.

## 실행 방법

```bash
# 1. 이미지 빌드
docker build -t agent-monitor .

# 2-a. 시스템 풀 기동 (sshd·cron·ufw·agent-app 전부 실행)
#      커맨드 'start-entrypoint' 입력 시에만 entrypoint.sh 가 동작한다.
docker run -d --cap-add=NET_ADMIN --name am agent-monitor start-entrypoint

# 2-b. 기본 docker run (bash 쉘만, entrypoint 미실행)
docker run -it --rm agent-monitor

# 3. 앱 부팅 로그 확인 (Boot Sequence 5/5, Agent READY)
docker logs am

# 4. 자동 검증
docker exec am verify.sh

# 5. monitor.sh 수동 실행
docker exec am su agent-admin -c /home/agent-admin/agent-app/bin/monitor.sh

# 6. cron 자동 누적 확인 (1~2분 후)
docker exec am tail /var/log/agent-app/monitor.log
```

## 파일

- `Dockerfile` — ubuntu:24.04 기반 환경 구성(패키지·계정·권한·복사·SSH 설정)
- `docker-wrapper.sh` — 컨테이너 진입점 래퍼. `start-entrypoint` 커맨드 시만 entrypoint 실행, 기본값 bash
- `entrypoint.sh` — 시스템 풀 기동(sshd·cron·ufw 기동, crontab 등록, 앱 실행)
- `monitor.sh` — 시스템 관제 스크립트(헬스체크·자원수집·임계값경고·로깅·로테이션)
- `verify.sh` — 요구사항 자동 검증(8항목)
- `MANUAL_VERIFICATION.md` — 수동 검증 체크리스트
- `agent-app-linux-x86` — 제공 애플리케이션 바이너리(실행 대상)
- `architecture.md` — 구조도(mermaid)
- `EXPLANATION.md` — 코드리뷰 수준 통합 설명 + 제약-코드 매핑표
- `README.md` — 본 문서

## 결과 요약

- 앱 Boot Sequence 5단계 전부 `[OK]`, `Agent READY`, 포트 15034 LISTEN 확인.
- `monitor.sh`가 cron으로 매분 실행되어 `monitor.log`에 라인 누적 확인.
- `verify.sh` 자동 검증 8개 항목 21개 점검 전부 통과(`PASS=21 FAIL=0`).
- 선택(보너스) 과제는 미수행.

## 참고

- 제공 바이너리는 `AGENT_KEY_PATH`를 키 디렉토리로, 키 파일명을 `secret.key`로 요구한다
  (PDF 예시 `t_secret.key`와 상이). 실행 대상 바이너리 사양을 따랐다 — 상세는
  `EXPLANATION.md` 참고.
- UFW는 컨테이너에서 `--cap-add=NET_ADMIN` 없이는 활성화되지 않는다.
