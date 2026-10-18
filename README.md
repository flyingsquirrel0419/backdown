# BackDown

LiveContainer에서 돌리는 iOS용 **백그라운드 다운로더 브라우저**.
모바일 Chrome/Safari처럼 앱을 나가면 다운로드가 끊기는 문제 없이, 브라우저에서 시작한 다운로드(IPA뿐 아니라 모든 파일)를 백그라운드에서 끝까지 받고, 끊기면 이어받습니다.

## 설치
1. [최신 IPA 다운로드](https://github.com/flyingsquirrel0419/backdown/releases/download/latest/BackDown.ipa)
2. LiveContainer → `+` → IPA 선택해서 설치 → 실행

## 기능
- 내장 브라우저(WKWebView): 주소창/검색, 뒤로·앞으로, 새 창 링크는 같은 창에서 열기
- 다운로드 자동 감지: `Content-Disposition: attachment`, 표시 불가 MIME, zip/ipa/octet-stream 등
- 링크 길게 누르기 → **BackDown으로 다운로드**, 하단 ⬇︎ 버튼으로 현재 페이지 URL 받기, 다운로드 탭 `+`로 URL 직접 입력
- 쿠키·User-Agent·Referer를 그대로 넘겨서 로그인이 필요한 링크도 받기
- 시스템 background `URLSession` → 앱이 백그라운드/종료돼도 계속 받음
- 다운로드 중에만 무음 오디오 재생으로 앱 프로세스 유지 (설정에서 끌 수 있음)
- 끊기면 resumeData로 이어받기, 네트워크 오류 시 자동 재시도(지수 백오프, 네트워크 복구 시 즉시 재개)
- 일시정지/재개/처음부터 다시/삭제, 진행률·속도·남은 시간, 완료/실패 알림
- 완료 파일은 `Documents/Downloads` 저장 → 공유 시트 또는 파일 앱(LiveContainer 항목 아래)

## 참고
- POST·blob 등 다시 요청할 수 없는 다운로드는 앱 내 다운로드(WKDownload)로 폴백되며, 이 경우는 앱이 살아 있어야 합니다.
- 한 번만 쓸 수 있는 토큰 링크는 브라우저가 첫 요청을 이미 보낸 뒤라 실패할 수 있습니다.
- 앱을 앱 전환기에서 위로 밀어 강제 종료하면 iOS가 백그라운드 전송을 취소합니다. 다시 실행하면 이어받기를 자동 시도합니다.

## 빌드
GitHub Actions(macOS)에서 XcodeGen → `xcodebuild` (서명 없음) → `BackDown.ipa`.
로컬(macOS): `brew install xcodegen && xcodegen generate && open BackDown.xcodeproj`
