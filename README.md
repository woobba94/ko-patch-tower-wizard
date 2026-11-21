# Tower Wizard 비공식 한국어 패치

Windows Steam판 Tower Wizard의 메뉴, 설정, 툴팁, 튜토리얼, 대사와 엔딩을 한국어로 표시하는 팬 번역입니다.

## 다운로드

[ko-patch-tower-wizard.cmd 다운로드](https://github.com/woobba94/ko-patch-tower-wizard/releases/latest/download/ko-patch-tower-wizard.cmd)

게임을 종료한 뒤 CMD 파일을 실행합니다. Steam 설치 폴더는 자동으로 찾습니다.

| 메뉴 | 동작 |
| --- | --- |
| **1. 한국어 적용 / 재설치** | 필요한 번역과 글꼴을 GitHub 릴리스에서 받아 검증합니다. 설치본과 호환되면 원본을 백업한 뒤 한국어를 적용합니다. |
| **2. 원본 복구** | 현재 적용된 패치와 짝이 맞는 원본 백업을 검증하고 복구합니다. 다운로드 없이 실행할 수 있습니다. |
| **3. 설치 상태 확인** | 설치 경로와 Steam 빌드, 패치 적용 상태를 표시합니다. |

적용 후 Steam에서 게임을 실행하면 한국어로 시작합니다. 설정에서 게임의 공식 언어도 선택할 수 있습니다.

## Steam 업데이트 이후

v1.1.0부터 Steam 빌드 번호와 관계없이 **같은 CMD**로 다시 적용할 수 있습니다. 게임 안의 번역 형식과 필요한 스크립트가 호환되면 현재 설치본에서 패치를 다시 조립합니다. 추가되거나 영어 원문이 바뀐 항목은 영어로 표시하고, 확인된 기존 번역은 계속 사용합니다.

패치에 필요한 스크립트나 번역 형식이 바뀌면 설치를 중단하고 사유를 화면에 표시합니다. 실제 게임 실행은 1.0.5(빌드 23289626)에서 확인했습니다. 변경된 빌드의 적용과 복구도 테스트 사본에서 검증했습니다.

백업은 게임 폴더에 `Tower Wizard.pck.ko-original.<원본 SHA-256 앞 12자>` 이름으로 생성됩니다. Steam 업데이트가 게임 파일을 교체한 뒤에는 이전 빌드 백업으로 복구하지 않습니다.

## 오류 제보

[GitHub 이슈](https://github.com/woobba94/ko-patch-tower-wizard/issues/new)에 CMD 버전, Steam 빌드, 선택한 메뉴와 오류 메시지를 적어 주세요. 호환성 오류에는 화면에 나온 PCK SHA-256을 함께 적어 주세요. 번역 오류는 화면 이름과 문구를 첨부해 주세요.

## 패치 데이터와 라이선스

릴리스 ZIP에는 번역, 갈무리 글꼴과 [KeyDot](https://github.com/Titoot/KeyDot)이 들어 있습니다. KeyDot은 설치된 실행 파일에서 PCK를 읽는 데 필요한 키를 얻는 데 사용합니다. CMD는 ZIP의 SHA-256을 확인한 뒤 로컬 Steam 파일로 패치를 조립합니다.

- 갈무리 9·11은 이민서가 제작한 픽셀 글꼴입니다. [글꼴 프로젝트](https://github.com/quiple/galmuri) · [SIL Open Font License 1.1](licenses/Galmuri-OFL-1.1.txt)
- KeyDot은 Titoot이 제작했습니다. [MIT 라이선스](licenses/KeyDot-MIT.txt)
