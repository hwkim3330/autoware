# CBOR 고장 데이터 테스팅 가이드 (CBOR Fault Data Testing Guide)

## 개요 (Overview)

본 문서는 ADB 브로드캐스트 명령어를 사용하여 CBOR 고장 데이터 표시 기능을 테스트하는 과정을 기술합니다.

## 데이터 파이프라인 (Data Pipeline)

![Data Flow](https://grden.github.io/projects/keti/keti-data.png)

## ADB를 활용한 테스팅 (Testing with ADB)

### 사전 준비 사항

1. 안드로이드 기기 또는 에뮬레이터에 애플리케이션을 빌드 및 설치합니다.
   ```bash
   cd /Users/jeongwon/dev/work/flutter_model_test
   flutter build apk
   flutter install
   ```

2. 애플리케이션이 실행 중이며 화면에 정상적으로 표시되는지 확인합니다.

### 기본 ADB 브로드캐스트 명령어 형식

```bash
adb shell am broadcast \
  -a com.pleos.SIMULATE_CBOR \
  --es cbor_hex "HEX_STRING_HERE"
```

### 테스트 케이스

**테스트 케이스 1: 단일 타겟에서 두 개의 오류 Fault 발생**

```bash
# {
#   "action": 1,            # 추가 = 1
#   "id": 1,
#   "code": 101,            # 유형 - 물리적 링크 단절(Link Shutdown)
#   "target": "RearZC",     # 위치 - Rear Zonal Controller
#   "severity": 2           # 심각도 - 2
# }
adb shell am broadcast \
  -a com.pleos.SIMULATE_CBOR \
  --es cbor_hex "A566616374696F6E016269640164636F646518656674617267657466526561725A4368736576657269747902"
  
# {
#   "action": 1,            # 추가 = 1
#   "id": 2,
#   "code": 102,            # 유형 - 비정상 트래픽(Babbling Idiot/Jabber)
#   "target": "RearZC",     # 위치 - Rear Zonal Controller
#   "severity": 2           # 심각도 - 2
# }
adb shell am broadcast \
  -a com.pleos.SIMULATE_CBOR \
  --es cbor_hex "A566616374696F6E016269640264636F646518666674617267657466526561725A4368736576657269747902"
```

**테스트 케이스 2: 경고 Fault 발생**

```bash
# {
#   "action": 1,                    # 추가 = 1
#   "id": 3,
#   "code": 103,                    # 유형 - 프레임 손상(Frame Corruption)
#   "target": "FrontCenterLidar",   # 위치 - Front Center Lidar
#   "severity": 1                   # 심각도 - 2
# }
adb shell am broadcast \
  -a com.pleos.SIMULATE_CBOR \
  --es cbor_hex "A566616374696F6E016269640364636F64651867667461726765747046726F6E7443656E7465724C6964617268736576657269747901"
```

**Fault 제거**

```bash
# {
#   "action": 0,    # 제거 = 0
#   "id": 3
# }
adb shell am broadcast \
  -a com.pleos.SIMULATE_CBOR \
  --es cbor_hex "A266616374696F6E0062696403"
```

**차량 상태 변경**

```bash
# 기어: 드라이브 (Drive)
adb shell "echo 'propId: 289408000 areaId: 0 values: 8' > /data/vendor/vsomeip/vhal_fifo" 

# 속도: 30km/h
adb shell "echo 'propId: 291504647 areaId: 0 values: 30' > /data/vendor/vsomeip/vhal_fifo"

# 속도: 0km/h
adb shell "echo 'propId: 291504647 areaId: 0 values: 0' > /data/vendor/vsomeip/vhal_fifo"
```

## 사용자 정의 CBOR Hex 문자열 생성 (Creating Custom CBOR Hex Strings)

### 온라인 CBOR 도구

- [cbor.me](https://cbor.me/) - Online CBOR encoder/decoder

## Fault Code 참조 (Fault Code Reference)

각 Fault Code에 해당하는 Fault 상세 정보는 `/lib/repositories/fault_code_mapper.dart` 파일 내 `faultCodeDatabase`에 정의되어 있습니다.

**Fault Code Mapping Data 예시**

```dart
const Map<int, FaultDetails> faultCodeDatabase = {
  // 10X: 예방을 통한 무중단(Hitless) 고장 대응 시나리오
  101: FaultDetails(
    faultType: '물리적 링크 단절(Link Shutdown)',
    cause: '케이블 절단, 커넥터 탈거, 진동으로 인한 접촉 불량, PHY칩 손상',
    countermeasures: ['ST, MEDIA 트래픽', 'FRER'],
  ),
};
```

## 실제 하드웨어 연동 (Integration with Real Hardware)
실제 하드웨어(Zonal Network)와 연동할 준비가 완료되면 다음 절차를 따르면 됩니다.

1. CborFaultService를 확장(extend)하여 실제 네트워크 소스를 수신하도록 수정합니다.
2. 파싱 로직(Hex → CBOR → JSON)은 기존과 동일하게 유지됩니다.
3. BroadcastReceiver를 실제 데이터 소스(소켓, CoAP 클라이언트 등)로 교체합니다.
4. Flutter 코드는 별도의 수정이 필요하지 않습니다.