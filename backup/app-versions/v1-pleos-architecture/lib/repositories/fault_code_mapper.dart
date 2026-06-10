import '../models/fault_data.dart';
import '../models/native_fault_data.dart';

class FaultDetails {
  final String faultType;
  final String cause;
  final List<String> countermeasures;

  const FaultDetails({
    required this.faultType,
    required this.cause,
    required this.countermeasures,
  });
}

/// NativeFaultData의 code에 따라 FaultDetails를 매핑하기 위한 데이터베이스
/// 각 항목은 '아키텍처 설계 문서' 내용 참고
const Map<int, FaultDetails> faultCodeDatabase = {
  // 10X: 예방을 통한 무중단(Hitless) 고장 대응 시나리오
  101: FaultDetails(
    faultType: '물리적 링크 단절(Link Shutdown)',
    cause: '케이블 절단, 커넥터 탈거, 진동으로 인한 접촉 불량, PHY칩 손상',
    countermeasures: ['ST, MEDIA 트래픽', 'FRER'],
  ),
  102: FaultDetails(
    faultType: '비정상 트래픽(Babbling Idiot/Jabber)',
    cause: 'TSN EP의 SW 오류 또는 HW 고장으로 인해 비정상적인 프레임 또는 정상 프레임을 끊임없이 전송',
    countermeasures: ['모든 트래픽/트래픽 차단'],
  ),
  103: FaultDetails(
    faultType: '프레임 손상(Frame Corruption)',
    cause: 'EMI, 케이블 노후화, 커넥터 손상 등으로 전송 프레임의 비트 변조',
    countermeasures: ['ST, MEDIA 트래픽/FRER'],
  ),
  104: FaultDetails(
    faultType: '큐 오버플로우 및 프레임 손실(Queue Saturation & Drop)',
    cause: '특정 ZC로 트래픽이 순간적으로 집중되거나, BE 트래픽이 과도하게 발생하여 스위치의 출력 큐 버퍼가 가득참',
    countermeasures: ['모든 트래픽/ATS', 'BE 트래픽/PSF P로 유입량 제한', 'ST/우선순위 큐잉'],
  ),
  105: FaultDetails(
    faultType: '잘못된 트래픽 스케쥴링(Shaper Misbehavior)',
    cause: 'TSN EP의 SW 오류로 인해 ATS로 제어되어야 할 스트림이 CIR/CBS를 위한하여 과도한 버스트 형태로 전송',
    countermeasures: ['모든 트래픽/ATS', '모든 트래픽/PSFP로 필터링'],
  ),
  106: FaultDetails(
    faultType: '설정 오류(Misconfiguration)',
    cause: 'VLAN/PCP 값 불일치',
    countermeasures: ['모든 트래픽/ZC의 Ingress Port 필터링 규칙 적용'],
  ),
  // 20X: 재구성을 통한 무중단(Hitless) 고장 대응 시나리오
  107: FaultDetails(
    faultType: '시간 동기 불안정(gPTP Instability)',
    cause: '경로 지연 비대칭',
    countermeasures: ['모든 노드/시간 정밀도가 높은 GM 선정', '링크/대칭 설계'],
  ),
  201: FaultDetails(
    faultType: '시간 동기 상실(Loss of Time Sync)',
    cause: 'GM 고장 또는 PTP 메시지 전파 경로 상 링크 단절',
    countermeasures: [
      'GM Failover: Secondary GM이 BMCA에 따라 새로운 GM 역할 수행',
      'PTP용 FRER 설정',
    ],
  ),
  202: FaultDetails(
    faultType: 'ZC 기능 정지(ZC Freeze/Crash)',
    cause: 'ZC의 SW 오류, HW 고장, 전원 공급 불안정',
    countermeasures: [
      '모든 트래픽/고장난 ZC를 경유하는 모든 트래픽은 대안 경로로 우회 혹은 FRER',
      'Watchdog에 의한 ZC 재부팅',
    ],
  ),
  203: FaultDetails(
    faultType: '중복 프레임 제거 실패(FRER Elimination Failure)',
    cause:
        'FRER의 Elimination 노드에 SW 오류가 발생하여 중복 프레임을 제거하지 못하고 복제본을 모두 상위 계층으로 전달',
    countermeasures: ['중복 프레임/중복 시퀀스를 통한 중복 메시지 제거 처리', 'FRER 재부팅'],
  ),
  204: FaultDetails(
    faultType: '느린 드레인 장치(Slow Drain Device)',
    cause: '특정 ZC 또는 EP의 패킷 처리 성능 저하로 인해 버퍼링 정체가 발생해 Pause 프레임의 지속적인 발생',
    countermeasures: ['ZC & EP/큐 분리', 'ZC & EP/Pause 급증 이벤트 발생', '재부팅'],
  ),
  205: FaultDetails(
    faultType: '주소 충돌(Address Conflict)',
    cause: '설정 오류로 인한 MAC주소, IP주소 중복',
    countermeasures: ['DHCP서버/DHCP 일시중지 후 재개', '중앙관제/주소 할당 재구성'],
  ),
  206: FaultDetails(
    faultType: '네트워크 과부하 (Sustained Congestion)',
    cause: 'Lidar의 예상치 못한 트래픽 패턴 발생',
    countermeasures: ['트래픽 정책 재구성을 통한 네트워크 재설계'],
  ),
  // 30X: 성능 저하 운행(Degraded Operation) 고장 대응 시나리오
  301: FaultDetails(
    faultType: '단일 Zone 완전 고립(Single zone Isolation)',
    cause: 'FL-ZC의 전원 완전 차단 혹은 복구 불가능한 고장',
    countermeasures: [
      'FR-ZC와 R-ZC로 선형 토폴로지로 동작 모드 변경',
      'FRER 기능 정지',
      '센서 퓨전 알고리즘을 통한 자율주행 기술 재구성',
    ],
  ),
  302: FaultDetails(
    faultType: '간헐적 링크 불안정이 지속적으로 발생해 센서 확보 불가',
    cause: 'FC-Lidar와 ZC 사이 링크의 간헐적 불안정',
    countermeasures: [
      '단일 경로 운용 (Fail-Operational): 안정적인 단일 경로로만 트래픽 발생',
      '무중단(Hitless) 이중화 중지',
      '하지만, 자율주행 기능은 정상 수행',
    ],
  ),
  303: FaultDetails(
    faultType: '네트워크 혼잡으로 인한 QoS 동작 재구성',
    cause: 'R-ZC의 처리 부하가 임계치에 도달',
    countermeasures: [
      '비핵심 스트림 우선 순위 강등',
      'R-ZC의 BE 입력 트래픽을 일시적으로 모두 필터링하도록 PSFP 설정',
      'ST 트래픽의 E2E 지연시간 안정성 유지',
    ],
  ),
  304: FaultDetails(
    faultType: 'GM 고장 및 백업 GM으로 전환',
    cause: 'GM의 고장',
    countermeasures: [
      '백업 GM 활성화',
      '시간 동기화 정밀도 하락으로 인해 TAS 기능 일시 중단',
      'ATS/SP 기반 운행 모드 전',
      '비핵심 트래픽 중단',
    ],
  ),
  305: FaultDetails(
    faultType: '“Rogue” GM 출현 및 시간 도메인 분리',
    cause: '비인가 시간 소스의 탐지',
    countermeasures: [
      '신뢰 기반 gPTP 정책 활성화(보안 재구성)',
      '안전 모드 운행 수행 (비상등 확인 활성화, 동기 센서 데이터 기반 기능 비활성화, 안전 속도로 감속 및 안전한 장소로 정차 등)',
    ],
  ),
  306: FaultDetails(
    faultType: 'VCU(주 차량제어기) 고장 및 Sub-VCU 백업',
    cause: 'VCU 고장',
    countermeasures: [
      '제어 권한 인수 (Failover): Sub-VCU가 제어권 인수해 활성화',
      'Path재구성: Sub-VCU와 ACU-IT 간의 경로 활성화',
      'Path재구성: Sub-VCU와 ACU-IT 간의 경로 상의 트래픽 큐 정책 활성화',
      'MRM 수행',
    ],
  ),
};

/// NativeFaultData의 code에 따라 FaultDetails를 매핑하는 함수
class FaultCodeMapper {
  static FaultData mapCodeToFaultData(NativeFaultData nativeFault) {
    final code = nativeFault.code ?? 0;
    final details = faultCodeDatabase[code];

    if (details == null) {
      // TODO: unknown fault code 표시 UI 만들기
      return FaultData(
        id: nativeFault.id,
        target: nativeFault.target ?? '',
        severity: nativeFault.severity ?? 1,
        faultType: '알 수 없는 고장 (Unknown Fault)',
        cause: '고장 코드 $code에 대한 정보가 없습니다.',
        countermeasures: [],
      );
    }

    return FaultData(
      id: nativeFault.id,
      target: nativeFault.target ?? '',
      severity: nativeFault.severity ?? 1,
      faultType: details.faultType,
      cause: details.cause,
      countermeasures: details.countermeasures,
    );
  }

  /// checks if a fault code exists in the database -> 안쓰임
  static bool isCodeKnown(int code) {
    return faultCodeDatabase.containsKey(code);
  }

  /// gets the list of all known fault codes -> 안쓰임
  static List<int> getAllKnownCodes() {
    return faultCodeDatabase.keys.toList();
  }
}
