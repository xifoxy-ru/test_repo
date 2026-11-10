# Earth Information Jukebox — 기획 초안

사용자는 검토된 mock 시제품 방향과 구현 진행에 동의했다. 아래 미확인 항목과 IMPLEMENTATION_READY 증거는 별도로 확인해야 한다.

- 챌린지: The Earth Information Jukebox — https://www.spaceappschallenge.org/2026/challenges/the-earth-information-jukebox/?tab=details
- [팀 소개](https://www.spaceappschallenge.org/2026/find-a-team/proteas/)에 대한 공식 검색 결과 스니펫에서 EIC의 시각 프레임과 실시간 sonification 결합 목표를 관찰했다(확인일 2026-11-11). 소개 페이지 자체의 직접 열기 성공 여부는 미확인이다. 챌린지 상세 페이지는 직접 접근에 실패했으므로 상세 요구·규정은 미확인이다. 참고용 [지역 행사 페이지](https://hackathlone.com/challenges/the-earth-information-jukebox)는 11월 13일 자료 공개 예정이라고 주장하나 공식 확정 정보는 아니다(확인일 2026-11-11).
- 목표 제안: 지구 현상을 시각화하고 소리로 표현해 사용자가 변화의 관계를 탐색한다.
- 대상 사용자와 구체 문제: 미정.
- 인원·시간·대상: 2명, 총 24시간, Windows 기기 2대. 사용자는 제품 방향과 최종 판단, 다른 팀원은 장비 사용 가능 시 Windows/Edge 실기 검증을 맡는다. 호스트는 macOS다.
- 제품 형태 및 스택: 웹, HTML/CSS/JavaScript 및 Web Audio API 선택. Windows Edge는 현재 장비를 사용할 수 없어 설치·버전·작동 검사를 장비 사용 가능 시로 연기한다. Chrome의 존재와 버전도 확인되지 않았다.
- 데이터: 사용자는 최종 제출 적합성 확인과 별개로 mock 시제품을 우선 진행하기로 결정했다. 실제 자료·출처·사용 조건은 미정이며 mock의 최종 제출 허용 여부는 공식 확인 전이다.
- 승인된 mock 시제품 핵심 흐름: 현상 선택 → mock 시각 프레임 또는 시계열 값 재생/정지 → 동기화된 소리, mock 표시와 변환 규칙 설명; 키보드와 음량 제어를 포함한다. 구체 현상은 미정이고 mock 데이터·매핑은 SPEC 계약을 따르며 실제 EIC 자료의 최종 요구는 미결이다.
- MVP 범위·성공 조건은 검토된 SPEC의 mock 시제품 계약을 따른다. 실제 제출 적합성과 공식 EIC 요구는 별도로 확인한다.
- 남은 확인·결정: 공식 상세 요구와 실제 EIC 자료 적용, mock의 최종 제출 허용·제출 방식, 구체 현상 및 최종 mock 내용, 대상 Windows 브라우저 버전과 실제 실행·검증 결과. mock MVP 흐름·변환 규칙, macOS 호스트와 사람 역할은 위 및 SPEC의 승인된 계약을 따른다.
