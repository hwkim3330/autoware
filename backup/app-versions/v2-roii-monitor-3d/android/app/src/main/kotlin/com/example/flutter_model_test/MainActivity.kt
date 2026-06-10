package com.example.flutter_model_test

import android.car.Car
import android.car.hardware.property.CarPropertyManager
import android.car.VehiclePropertyIds
import android.car.hardware.CarPropertyValue
import android.content.pm.PackageManager
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.annotation.NonNull
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    // 채널 이름 정의
    private val SPEED_CHANNEL = "com.example/car_speed_stream"
    private val FAULT_CHANNEL = "com.example/fault_data_stream"
    private val PERMISSION_CHANNEL = "com.example/permissions"

    // 권한 요청 코드
    private val CAR_SPEED_PERMISSION_REQUEST_CODE = 1001

    // 메인 스레드로 작업을 보내기 위한 핸들러
    private val mainThreadHandler = Handler(Looper.getMainLooper())
    
    // CBOR Fault Service
    private var cborFaultService: CborFaultService? = null

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // --- 1. 권한 요청을 위한 MethodChannel ---
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, PERMISSION_CHANNEL).setMethodCallHandler { call, result ->
            if (call.method == "requestCarSpeedPermission") {
                checkAndRequestSpeedPermission(result)
            } else {
                result.notImplemented()
            }
        }

        // --- 2. 차량 속도 EventChannel (AAOS API) ---
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, SPEED_CHANNEL).setStreamHandler(
            object : EventChannel.StreamHandler {
                private var car: Car? = null
                private var propertyManager: CarPropertyManager? = null
                private var carPropertyCallback: CarPropertyManager.CarPropertyEventCallback? = null

                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    Log.d("MainActivity", "속도 스트림 구독 시작 (가용성 체크 포함)")
                    try {
                        if (!packageManager.hasSystemFeature(PackageManager.FEATURE_AUTOMOTIVE)) {
                            throw IllegalStateException("이 기기는 AAOS가 아닙니다.")
                        }

                        car = Car.createCar(this@MainActivity)
                        propertyManager = car!!.getCarManager(Car.PROPERTY_SERVICE) as CarPropertyManager

                        // 핵심: 속성 가용성 확인 (SecurityException 방지)
                        if (propertyManager!!.isPropertyAvailable(VehiclePropertyIds.PERF_VEHICLE_SPEED, 0)) {
                            Log.d("MainActivity", "차량 속도 속성을 사용할 수 있습니다. 콜백을 등록합니다.")

                            carPropertyCallback = object : CarPropertyManager.CarPropertyEventCallback {
                                override fun onChangeEvent(value: CarPropertyValue<*>) {
                                    if (value.propertyId == VehiclePropertyIds.PERF_VEHICLE_SPEED) {
                                        val speedInMps = value.value as Float
                                        val speedInKmh = speedInMps * 3.6f
                                        mainThreadHandler.post { events?.success(speedInKmh) }
                                    }
                                }
                                override fun onErrorEvent(propId: Int, zone: Int) {
                                    Log.w("MainActivity", "속도 속성 오류 발생: propId=$propId")
                                    mainThreadHandler.post { events?.error("SPEED_ERROR", "속도 센서 오류", "propId: $propId") }
                                }
                            }

                            propertyManager!!.registerCallback(
                                carPropertyCallback!!,
                                VehiclePropertyIds.PERF_VEHICLE_SPEED,
                                CarPropertyManager.SENSOR_RATE_NORMAL
                            )
                        } else {
                            Log.e("MainActivity", "오류: 이 에뮬레이터는 차량 속도 속성을 지원하지 않습니다.")
                            mainThreadHandler.post {
                                events?.error("UNAVAILABLE", "차량 속도 속성을 사용할 수 없습니다.", null)
                            }
                        }
                    } catch (e: Exception) {
                        Log.e("MainActivity", "속도 채널 설정 중 예외 발생", e)
                        mainThreadHandler.post { events?.error("SPEED_INIT_ERROR", "초기화 실패", e.message) }
                    }
                }

                override fun onCancel(arguments: Any?) {
                    Log.d("MainActivity", "속도 스트림 구독 취소")
                    if (propertyManager != null && carPropertyCallback != null) {
                        propertyManager!!.unregisterCallback(carPropertyCallback!!)
                    }
                    car?.disconnect()
                }
            }
        )
        
        // --- 3. 고장 데이터 EventChannel (CBOR via ADB Broadcast) ---
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, FAULT_CHANNEL).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    Log.d("MainActivity", "고장 데이터 스트림 구독 시작")
                    try {
                        // Initialize CBOR Fault Service if not already created
                        if (cborFaultService == null) {
                            cborFaultService = CborFaultService(this@MainActivity)
                        }
                        
                        // Set the event sink and start listening
                        cborFaultService?.setEventSink(events)
                        cborFaultService?.startListening()
                        
                        Log.d("MainActivity", "CBOR Fault Service 시작됨")
                    } catch (e: Exception) {
                        Log.e("MainActivity", "고장 데이터 채널 설정 중 예외 발생", e)
                        mainThreadHandler.post {
                            events?.error("FAULT_INIT_ERROR", "초기화 실패", e.message)
                        }
                    }
                }

                override fun onCancel(arguments: Any?) {
                    Log.d("MainActivity", "고장 데이터 스트림 구독 취소")
                    cborFaultService?.setEventSink(null)
                }
            }
        )
    }

    override fun onDestroy() {
        super.onDestroy()
        // Clean up CBOR service when activity is destroyed
        cborFaultService?.stopListening()
        cborFaultService = null
    }

    // --- 4. 권한 확인 및 요청 로직 ---
    private fun checkAndRequestSpeedPermission(result: MethodChannel.Result) {
        val permission = "android.car.permission.CAR_SPEED"
        if (ContextCompat.checkSelfPermission(this, permission) == PackageManager.PERMISSION_GRANTED) {
            // 이미 권한이 있으면 true 반환
            Log.d("MainActivity", "CAR_SPEED 권한이 이미 있습니다.")
            result.success(true)
        } else {
            // 권한이 없으면 사용자에게 요청 팝업을 띄움
            Log.d("MainActivity", "CAR_SPEED 권한 요청 팝업을 띄웁니다.")
            ActivityCompat.requestPermissions(this, arrayOf(permission), CAR_SPEED_PERMISSION_REQUEST_CODE)
            // Flutter에는 '아직 권한 없음'을 즉시 알림
            result.success(false)
        }
    }

    // 5. 권한 요청 팝업의 결과를 받는 콜백 (필수는 아님)
    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == CAR_SPEED_PERMISSION_REQUEST_CODE) {
            if (grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED) {
                Log.d("MainActivity", "CAR_SPEED 권한이 사용자에 의해 부여됨")
                // 참고: 이 시점에 Flutter로 "권한 부여됨!"이라고 이벤트를 보내 UI를 자동 갱신시킬 수도 있음.
                // 현재는 사용자가 버튼을 다시 눌러야 갱신됨.
            } else {
                Log.d("MainActivity", "CAR_SPEED 권한이 거부됨")
            }
        }
    }
}