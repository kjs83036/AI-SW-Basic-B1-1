# 시스템 관제 자동화 스크립트

다중 사용자 환경을 위한 강화된 보안 제어가 포함된 Linux 시스템 모니터링 및 자동화 솔루션입니다.

## 개요

이 프로젝트는 실시간 헬스 체크, 리소스 모니터링, 자동 로깅을 수행하는 종합적인 시스템 관제 자동화 스크립트(`monitor.sh`)를 구현합니다.

## 주요 기능

- **SSH 보안**: 커스텀 포트(20022)와 Root 원격 접속 차단
- **방화벽 관리**: UFW 방화벽으로 필요 포트만 허용(20022/tcp, 15034/tcp)
- **다중 사용자 환경**: 역할 기반 접근 제어(RBAC) - 3가지 사용자 타입(admin, dev, test)
- **헬스 모니터링**: 프로세스 및 포트 가용성 자동 확인
- **리소스 모니터링**: CPU, 메모리, 디스크 사용률 추적 및 임계값 경고
- **자동 로깅**: Cron 기반 실행과 자동 로그 로테이션(10MB × 10개 파일)
- **ACL 기반 권한**: POSIX ACL 상속으로 안전한 디렉토리 접근 제어

## 프로젝트 구조

```
.
├── monitor.sh                # 시스템 관제 자동화 스크립트
├── 수행내역서.md             # 수행 내역 및 증거 자료
└── README.md                 # 본 문서
```

## 기술 스택

- **호스트 OS**: OrbStack 기반 macOS
- **게스트 OS**: Ubuntu 24.04 LTS (GLIBC 2.39+)
- **셸**: Bash 5.x
- **도구**: UFW, SSH, cron, ACL, systemd

## 설치 및 배포

### 사전 요구사항

- macOS에 OrbStack 2.0 이상 설치
- Ubuntu 24.04 LTS 게스트 머신
- 초기 설정 단계(Phase 1-6)에서 root 권한 필요

### 빠른 시작

1. **OrbStack 머신 생성**
   ```bash
   orb create -a amd64 ubuntu:24.04 agent-lab
   ```

2. **시스템 부트스트랩** (root/sudo 사용자로)
   ```bash
   sudo apt update && sudo apt install -y openssh-server ufw acl cron
   ```

3. **SSH 및 방화벽 설정**
   - SSH 포트를 20022로 변경
   - Root 원격 접속 차단
   - UFW 활성화 및 20022/tcp, 15034/tcp 허용

4. **사용자 및 그룹 생성**
   - `agent-admin` (관리자)
   - `agent-dev` (개발자)
   - `agent-test` (테스트)
   - 그룹: `agent-common`, `agent-core`

5. **모니터링 스크립트 배포**
   ```bash
   cp monitor.sh /home/agent-admin/agent-app/bin/monitor.sh
   chmod 750 /home/agent-admin/agent-app/bin/monitor.sh
   ```

6. **Crontab 등록** (agent-admin으로)
   ```bash
   crontab -e
   # 추가: * * * * * /home/agent-admin/agent-app/bin/monitor.sh >> /var/log/agent-app/monitor.cron.out 2>&1
   ```

## 모니터 스크립트 상세

### 헬스 체크
- 프로세스 실행 확인: `pgrep -x agent-app`
- 포트 LISTEN 확인: `ss -tln sport = :15034`

### 리소스 메트릭
- **CPU 사용률**: 비유휴(non-idle) CPU 시간의 백분율
- **메모리 사용률**: 사용 중인 메모리의 전체 대비 백분율
- **디스크 사용률**: 루트 파티션 사용률 백분율

### 임계값 경고
- CPU > 20% → [WARNING]
- 메모리 > 10% → [WARNING]
- 디스크 > 80% → [WARNING]

### 로그 포맷
```
[YYYY-MM-DD HH:MM:SS] PID:<pid> CPU:<x>% MEM:<x>% DISK_USED:<x>%
```

### 로그 로테이션
- 최대 파일 크기: 10MB
- 최대 보관 파일 수: 10개(monitor.log, .1 ~ .9)
- 크기 임계값 도달 시 자동 로테이션

## 권한 모델

| 디렉토리 | 소유자 | 그룹 | 권한 | ACL |
|---------|--------|------|------|-----|
| upload_files | agent-admin | agent-common | 2770 | rwx (상속) |
| api_keys | agent-admin | agent-core | 2770 | rwx (상속) |
| /var/log/agent-app | agent-admin | agent-core | 2770 | rwx (상속) |
| monitor.sh | agent-dev | agent-core | 750 | - |

## 사용 방법

### 수동 실행
```bash
/home/agent-admin/agent-app/bin/monitor.sh
```

### 자동 실행
Cron 등록 후 매분 자동으로 스크립트 실행됩니다.

### 로그 확인
```bash
tail -f /var/log/agent-app/monitor.log
```

## 보안 하이라이트

✓ SSH 포트 변경 (기본 22 → 20022)
✓ Root 원격 접속 차단
✓ 방화벽 활성화 (최소 포트 노출)
✓ 역할 기반 접근 제어(RBAC)
✓ ACL 기반 권한 상속
✓ 키 및 로그 디렉토리 분리 및 제한
✓ 프로세스 헬스 체크로 행(hang) 상태 방지

## 문서

[수행내역서.md](./수행내역서.md)에서 완전한 배포 증거 자료와 검증 단계를 확인할 수 있습니다.
