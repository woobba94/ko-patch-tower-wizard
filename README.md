# Tower Wizard 비공식 한국어 패치

Steam판 Tower Wizard의 메뉴, 설정, 툴팁, 튜토리얼, 대사와 엔딩을 한국어로 표시합니다. 원작 개발사와 Steam의 공식 패치와는 별개인 팬 번역입니다.

## 다운로드

Windows에서 [ko-patch-tower-wizard.cmd 다운로드](https://github.com/woobba94/ko-patch-tower-wizard/releases/latest/download/ko-patch-tower-wizard.cmd) 링크로 받은 파일 하나를 실행합니다. Steam 설치 폴더는 자동으로 찾습니다.

| 메뉴 | 동작 |
| --- | --- |
| **1. 한국어 적용 / 재설치** | 게임을 종료한 상태에서 실행합니다. CMD가 설치된 PCK를 확인하고, GitHub 릴리스에서 필요한 번역 데이터와 갈무리 글꼴을 받아 검증합니다. 원본을 백업한 뒤 패치를 적용합니다. |
| **2. 원본 복구** | 같은 CMD가 로컬에 저장된 원본 백업을 검증하고 복구합니다. |
| **3. 지원 빌드 확인** | 이 CMD가 지원하는 Steam 빌드와 원본 PCK의 SHA-256을 표시합니다. |

성공 후 Steam에서 게임을 실행하면 한국어로 시작합니다. 게임 안의 설정에서 기존 언어를 다시 선택할 수 있습니다.

## 지원하는 Steam 빌드

| 게임 버전 | Steam 빌드 | 원본 PCK SHA-256 |
| --- | --- | --- |
| 1.0.5 | 23289626 | 283fe09ff8481568e31ca73127d61fac71be2fdff09c159604e5c09048f9e083 |

적용 여부는 설치된 PCK의 SHA-256으로 판단합니다. 미지원 빌드는 게임 파일을 바꾸기 전에 안내합니다. Steam 업데이트 뒤에는 최신 CMD의 메뉴 3에서 지원 목록을 확인할 수 있습니다. 다운로드 파일은 해당 CMD 버전의 GitHub 릴리스에 연결되어 있습니다.

백업은 게임 폴더에 'Tower Wizard.pck.ko-original.283fe09ff848' 이름으로 저장됩니다. 복구는 이 파일을 사용합니다.

## 오류 제보

[GitHub 이슈](https://github.com/woobba94/ko-patch-tower-wizard/issues/new)에 사용한 CMD 릴리스, Steam 빌드, 설치·복구 중 선택한 메뉴와 오류 메시지를 적어 주세요. 미지원 설치본 안내가 표시되면 화면에 나온 PCK SHA-256도 함께 적어 주세요. 번역 오류는 어느 화면에서 어느 문구가 보였는지 알려 주세요.

## 패치 데이터와 글꼴

GitHub 릴리스에는 실행용 CMD와 CMD가 내려받는 패치 데이터 ZIP이 함께 올라갑니다. ZIP은 변경 데이터와 글꼴을 담으며, 적용할 PCK는 Steam 설치본의 파일에서 로컬로 조립합니다.

갈무리 9·11은 이민서가 제작했으며 SIL Open Font License 1.1을 따릅니다. [글꼴 프로젝트](https://github.com/quiple/galmuri) · [라이선스 전문](licenses/Galmuri-OFL-1.1.txt)
