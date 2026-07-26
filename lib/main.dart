import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';

void main() {
  runApp(const PremiumACApp());
}

class PremiumACApp extends StatelessWidget {
  const PremiumACApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'AC Smart Control',
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF0B0E14),
      ),
      home: const ThermostatScreen(),
    );
  }
}

class ThermostatScreen extends StatefulWidget {
  const ThermostatScreen({super.key});

  @override
  State<ThermostatScreen> createState() => _ThermostatScreenState();
}

class _ThermostatScreenState extends State<ThermostatScreen> with TickerProviderStateMixin {
  // 🛜 МРЕЖОВИ НАСТРОЙКИ (HTTP & MQTT)
  final TextEditingController _ipController = TextEditingController(text: '192.168.4.1');
  final TextEditingController _mqttBrokerController = TextEditingController(text: 'broker.hivemq.com');
  final TextEditingController _mqttTopicController = TextEditingController(text: 'home/ac/control');
  
  bool isConnectedToNodeMCU = false;
  bool isMqttConnected = false;
  Timer? _syncTimer;
  MqttServerClient? _mqttClient;

  double targetTemp = 22.0;
  double currentRoomTemp = 24.5;
  bool isPowerOn = false; 

  double externalTemp = 28.0;
  int externalHumidity = 40;

  Timer? _clockTimer;
  String _currentTime = '';
  String _currentDate = '';

  int activeWorkSeconds = 240;
  int activeRestSeconds = 180;
  int pendingWorkSeconds = 240;
  int pendingRestSeconds = 180;
  bool hasPendingChanges = false;

  bool isCompressorRunning = false;
  int remainingSeconds = 240;
  Timer? _cycleTimer;

  bool isSettingsExpanded = false;

  late AnimationController _snowflakeController;
  final List<Snowflake> _snowflakes = List.generate(20, (index) => Snowflake());

  @override
  void initState() {
    super.initState();
    _loadSavedSettings();
    _updateDateTime();

    _clockTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      _updateDateTime();
    });

    _startCompressorCycle();

    _snowflakeController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 10),
    )..repeat();

    _syncTimer = Timer.periodic(const Duration(seconds: 3), (timer) {
      _syncWithNodeMCU();
    });
  }

  // 💾 Зареждане на запазените мрежови настройки
  Future<void> _loadSavedSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _ipController.text = prefs.getString('nodemcu_ip') ?? '192.168.4.1';
      _mqttBrokerController.text = prefs.getString('mqtt_broker') ?? 'broker.hivemq.com';
      _mqttTopicController.text = prefs.getString('mqtt_topic') ?? 'home/ac/control';
    });
  }

  // 💾 Записване на мрежовите настройки в паметта
  Future<void> _saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('nodemcu_ip', _ipController.text.trim());
    await prefs.setString('mqtt_broker', _mqttBrokerController.text.trim());
    await prefs.setString('mqtt_topic', _mqttTopicController.text.trim());
  }

  // 🔌 Инициализиране и свързване към MQTT брокер за отдалечен достъп
  Future<void> _connectMqtt() async {
    String broker = _mqttBrokerController.text.trim();
    if (broker.isEmpty) return;

    _mqttClient = MqttServerClient(broker, 'flutter_ac_client_${DateTime.now().millisecondsSinceEpoch}');
    _mqttClient!.port = 1883;
    _mqttClient!.keepAlivePeriod = 20;
    _mqttClient!.logging(on: false);

    final connMessage = MqttConnectMessage()
        .withClientIdentifier('FlutterAcClient')
        .startClean();
    _mqttClient!.connectionMessage = connMessage;

    try {
      await _mqttClient!.connect();
    } catch (e) {
      _mqttClient!.disconnect();
      setState(() => isMqttConnected = false);
      return;
    }

    if (_mqttClient!.connectionStatus!.state == MqttConnectionState.connected) {
      setState(() => isMqttConnected = true);
      
      // Абониране за топик за обратна връзка (ако NodeMCU връща данни натам)
      String topic = _mqttTopicController.text.trim();
      _mqttClient!.subscribe(topic, MqttQos.atMostOnce);

     _mqttClient!.updates!.listen((List<MqttReceivedMessage<MqttMessage?>> c) {
        final recMess = c[0].payload as MqttPublishMessage;
        final payload = const Utf8Decoder().convert(recMess.payload.message);
        // Тук може да парсираш JSON от MQTT
      });
    } else {
      setState(() => isMqttConnected = false);
    }
  }

  // 📡 Изпращане на команда през MQTT (за отдалечен достъп)
  void _sendMqttCommand() {
    if (_mqttClient == null || _mqttClient!.connectionStatus!.state != MqttConnectionState.connected) {
      _connectMqtt();
      return;
    }

    String topic = _mqttTopicController.text.trim();
    final builder = MqttClientPayloadBuilder();
    
    final payloadMap = {
      "power": isPowerOn ? 1 : 0,
      "target": targetTemp,
      "work": activeWorkSeconds,
      "rest": activeRestSeconds
    };
    
    builder.addString(jsonEncode(payloadMap));
    _mqttClient!.publishMessage(topic, MqttQos.atMostOnce, builder.payload!);
  }

  void _updateDateTime() {
    final now = DateTime.now();
    setState(() {
      _currentTime = DateFormat('HH:mm:ss').format(now);
      _currentDate = DateFormat('dd.MM.yyyy').format(now);
    });
  }

  @override
  void dispose() {
    _clockTimer?.cancel();
    _cycleTimer?.cancel();
    _syncTimer?.cancel();
    _ipController.dispose();
    _mqttBrokerController.dispose();
    _mqttTopicController.dispose();
    _mqttClient?.disconnect();
    _snowflakeController.dispose();
    super.dispose();
  }

  Future<void> _syncWithNodeMCU() async {
    final ip = _ipController.text.trim();
    if (ip.isEmpty) return;

    try {
      final url = Uri.parse('http://$ip/update?power=${isPowerOn ? 1 : 0}&target=$targetTemp&work=$activeWorkSeconds&rest=$activeRestSeconds');
      final response = await http.get(url).timeout(const Duration(seconds: 2));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        setState(() {
          isConnectedToNodeMCU = true;
          if (data['roomTemp'] != null) currentRoomTemp = (data['roomTemp'] as num).toDouble();
          if (data['extTemp'] != null) externalTemp = (data['extTemp'] as num).toDouble();
          if (data['humidity'] != null) externalHumidity = data['humidity'] as int;
          if (data['compressor'] != null) isCompressorRunning = data['compressor'] == 1;
          if (data['remaining'] != null) remainingSeconds = data['remaining'] as int;
        });
      }
    } catch (e) {
      setState(() {
        isConnectedToNodeMCU = false;
      });
    }
  }

  void _startCompressorCycle() {
    _cycleTimer?.cancel();
    _cycleTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!isPowerOn) return;

      setState(() {
        if (remainingSeconds > 0) {
          remainingSeconds--;
        } else {
          activeWorkSeconds = pendingWorkSeconds;
          activeRestSeconds = pendingRestSeconds;
          hasPendingChanges = false;

          isCompressorRunning = !isCompressorRunning;
          remainingSeconds = isCompressorRunning ? activeWorkSeconds : activeRestSeconds;
        }
      });
    });
  }

  String _formatTime(int totalSeconds) {
    int mins = totalSeconds ~/ 60;
    int secs = totalSeconds % 60;
    return '${mins.toString().padLeft(2, '0')}:${secs.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          Container(
            decoration: const BoxDecoration(
              gradient: RadialGradient(
                center: Alignment(0, -0.3),
                radius: 1.3,
                colors: [Color(0xFF182232), Color(0xFF07090E)],
              ),
            ),
          ),

          if (isPowerOn)
            AnimatedBuilder(
              animation: _snowflakeController,
              builder: (context, child) {
                return CustomPaint(
                  size: Size.infinite,
                  painter: SnowflakePainter(_snowflakes, _snowflakeController.value),
                );
              },
            ),

          SafeArea(
            child: SingleChildScrollView(
              physics: const BouncingScrollPhysics(),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20.0, vertical: 12.0),
                child: Column(
                  children: [
                    _buildNetworkHeader(),
                    const SizedBox(height: 16),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Климатизация',
                              style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Colors.white),
                            ),
                            const SizedBox(height: 2),
                            Row(
                              children: [
                                Container(
                                  width: 8,
                                  height: 8,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: isPowerOn ? const Color(0xFF00E5FF) : Colors.redAccent,
                                  ),
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  isPowerOn ? 'АКТИВЕН' : 'ИЗКЛЮЧЕН',
                                  style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.grey[400], letterSpacing: 1.0),
                                ),
                              ],
                            ),
                          ],
                        ),
                        _buildPowerButton(),
                      ],
                    ),
                    const SizedBox(height: 15),

                    // Термостат колело
                    GestureDetector(
                      onPanUpdate: isPowerOn
                          ? (details) {
                              setState(() {
                                targetTemp -= details.delta.dy * 0.05;
                                if (targetTemp < 16.0) targetTemp = 16.0;
                                if (targetTemp > 30.0) targetTemp = 30.0;
                              });
                            }
                          : null,
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          SizedBox(
                            width: 210,
                            height: 210,
                            child: CustomPaint(
                              painter: WheelPainter(
                                progress: (targetTemp - 16.0) / (30.0 - 16.0),
                                isActive: isPowerOn,
                              ),
                            ),
                          ),
                          Container(
                            width: 160,
                            height: 160,
                            decoration: const BoxDecoration(
                              shape: BoxShape.circle,
                              color: Color(0xFF0E131F),
                            ),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Text(
                                  'СТАЙНА ${currentRoomTemp.toStringAsFixed(1)}°C',
                                  style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.grey[500]),
                                ),
                                const SizedBox(height: 4),
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      targetTemp.toStringAsFixed(1),
                                      style: TextStyle(fontSize: 44, fontWeight: FontWeight.w900, color: isPowerOn ? Colors.white : Colors.grey[700], height: 1),
                                    ),
                                    Text('°C', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: isPowerOn ? const Color(0xFF00E5FF) : Colors.grey[700])),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 15),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        _buildCircleControlBtn(
                          icon: Icons.remove_rounded,
                          onTap: isPowerOn ? () => setState(() { if (targetTemp > 16.0) targetTemp -= 0.5; }) : null,
                        ),
                        const SizedBox(width: 30),
                        _buildCircleControlBtn(
                          icon: Icons.add_rounded,
                          onTap: isPowerOn ? () => setState(() { if (targetTemp < 30.0) targetTemp += 0.5; }) : null,
                          isPrimary: true,
                        ),
                      ],
                    ),

                    const SizedBox(height: 20),
                    
                    // Брояч таймер
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.04),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: Colors.white10),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            !isPowerOn ? 'Компресор: В ОЧАКВАНЕ' : (isCompressorRunning ? 'Компресор: РАБОТА' : 'Компресор: ПОЧИВКА'),
                            style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: isCompressorRunning ? const Color(0xFF00E5FF) : Colors.orangeAccent),
                          ),
                          Text(isPowerOn ? _formatTime(remainingSeconds) : '--:--', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: Colors.white)),
                        ],
                      ),
                    ),

                    const SizedBox(height: 16),

                    // Лента бутони
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(4),
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.04),
                        borderRadius: BorderRadius.circular(25),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Container(
                              padding: const EdgeInsets.symmetric(vertical: 12),
                              decoration: BoxDecoration(
                                color: isPowerOn ? const Color(0xFF00E5FF) : Colors.white10,
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: Center(
                                child: Text('ОХЛАЖДАНЕ', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: isPowerOn ? Colors.black : Colors.grey)),
                              ),
                            ),
                          ),
                          Expanded(
                            child: GestureDetector(
                              onTap: () => setState(() => isSettingsExpanded = !isSettingsExpanded),
                              child: Container(
                                padding: const EdgeInsets.symmetric(vertical: 12),
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Text('НАСТРОЙКА', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: isSettingsExpanded ? const Color(0xFF00E5FF) : Colors.grey[300])),
                                    Icon(isSettingsExpanded ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down, color: Colors.grey),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),

                    // Разширен панел с МРЕЖА (IP + MQTT) И ЗАПИС
                    AnimatedCrossFade(
                      firstChild: const SizedBox(width: double.infinity),
                      secondChild: Container(
                        margin: const EdgeInsets.only(top: 12),
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: const Color(0xFF131A28),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: const Color(0xFF00E5FF).withOpacity(0.2)),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('Локална мрежа (NodeMCU IP)', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Colors.white)),
                            const SizedBox(height: 6),
                            TextField(
                              controller: _ipController,
                              style: const TextStyle(fontSize: 13, color: Colors.white),
                              decoration: InputDecoration(
                                filled: true,
                                fillColor: Colors.black26,
                                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
                                hintText: '192.168.1.100',
                              ),
                            ),
                            const SizedBox(height: 12),
                            const Text('MQTT Брокер (Отдалечен достъп)', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Colors.white)),
                            const SizedBox(height: 6),
                            TextField(
                              controller: _mqttBrokerController,
                              style: const TextStyle(fontSize: 13, color: Colors.white),
                              decoration: InputDecoration(
                                filled: true,
                                fillColor: Colors.black26,
                                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
                                hintText: 'broker.hivemq.com',
                              ),
                            ),
                            const SizedBox(height: 8),
                            TextField(
                              controller: _mqttTopicController,
                              style: const TextStyle(fontSize: 13, color: Colors.white),
                              decoration: InputDecoration(
                                filled: true,
                                fillColor: Colors.black26,
                                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
                                hintText: 'home/ac/control',
                              ),
                            ),
                            const SizedBox(height: 12),
                            SizedBox(
                              width: double.infinity,
                              child: ElevatedButton(
                                onPressed: () async {
                                  await _saveSettings();
                                  _syncWithNodeMCU();
                                  _connectMqtt();
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(content: Text('Настройките са запазени и мрежите са рестартирани!'), duration: Duration(seconds: 1)),
                                  );
                                },
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: const Color(0xFF00E5FF),
                                  foregroundColor: Colors.black,
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                ),
                                child: const Text('ЗАПИШИ И СВЪРЖИ', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                              ),
                            ),
                            const Divider(color: Colors.white10, height: 24),
                            const Text('Настройки на таймера за релето', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.white)),
                            const SizedBox(height: 12),
                            
                            // Слайдър работа
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                const Text('Време за Работа:', style: TextStyle(fontSize: 12, color: Colors.white70)),
                                Text('${_formatTime(pendingWorkSeconds)} мин.', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Color(0xFF00E5FF))),
                              ],
                            ),
                            Slider(
                              value: pendingWorkSeconds.toDouble(),
                              min: 10,
                              max: 900,
                              activeColor: const Color(0xFF00E5FF),
                              onChanged: (val) {
                                setState(() {
                                  pendingWorkSeconds = val.round();
                                  hasPendingChanges = true;
                                });
                              },
                            ),
                            const SizedBox(height: 8),

                            // Слайдър почивка
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                const Text('Време за Почивка:', style: TextStyle(fontSize: 12, color: Colors.white70)),
                                Text('${_formatTime(pendingRestSeconds)} мин.', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.orangeAccent)),
                              ],
                            ),
                            Slider(
                              value: pendingRestSeconds.toDouble(),
                              min: 10,
                              max: 900,
                              activeColor: Colors.orangeAccent,
                              onChanged: (val) {
                                setState(() {
                                  pendingRestSeconds = val.round();
                                  hasPendingChanges = true;
                                });
                              },
                            ),
                          ],
                        ),
                      ),
                      crossFadeState: isSettingsExpanded ? CrossFadeState.showSecond : CrossFadeState.showFirst,
                      duration: const Duration(milliseconds: 300),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNetworkHeader() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF131A28),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(_currentTime, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Colors.white)),
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                decoration: BoxDecoration(
                  color: isConnectedToNodeMCU ? Colors.green.withOpacity(0.2) : Colors.red.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  isConnectedToNodeMCU ? 'IP OK' : 'IP No',
                  style: TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: isConnectedToNodeMCU ? Colors.greenAccent : Colors.redAccent),
                ),
              ),
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                decoration: BoxDecoration(
                  color: isMqttConnected ? Colors.blue.withOpacity(0.2) : Colors.grey.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  isMqttConnected ? 'MQTT OK' : 'MQTT Off',
                  style: TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: isMqttConnected ? Colors.blueAccent : Colors.grey),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildPowerButton() {
    return GestureDetector(
      onTap: () {
        setState(() {
          isPowerOn = !isPowerOn;
          if (!isPowerOn) isCompressorRunning = false;
        });
        _syncWithNodeMCU();
        _sendMqttCommand();
      },
      child: Container(
        width: 50,
        height: 50,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: isPowerOn ? const Color(0xFF00E5FF) : const Color(0xFF131A28),
        ),
        child: Icon(Icons.power_settings_new_rounded, color: isPowerOn ? Colors.black : Colors.grey[400]),
      ),
    );
  }

  Widget _buildCircleControlBtn({required IconData icon, VoidCallback? onTap, bool isPrimary = false}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: isPrimary ? const Color(0xFF00E5FF).withOpacity(0.15) : Colors.white.withOpacity(0.05),
        ),
        child: Icon(icon, color: isPrimary ? const Color(0xFF00E5FF) : Colors.white70),
      ),
    );
  }
}

class WheelPainter extends CustomPainter {
  final double progress;
  final bool isActive;
  WheelPainter({required this.progress, required this.isActive});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = min(size.width / 2, size.height / 2) - 8;
    final bgPaint = Paint()..color = Colors.white12..style = PaintingStyle.stroke..strokeWidth = 6..strokeCap = StrokeCap.round;
    final progressPaint = Paint()..color = isActive ? const Color(0xFF00E5FF) : Colors.grey[700]!..style = PaintingStyle.stroke..strokeWidth = 6..strokeCap = StrokeCap.round;
    const startAngle = 0.75 * pi;
    const sweepAngle = 1.5 * pi;
    canvas.drawArc(Rect.fromCircle(center: center, radius: radius), startAngle, sweepAngle, false, bgPaint);
    canvas.drawArc(Rect.fromCircle(center: center, radius: radius), startAngle, sweepAngle * progress, false, progressPaint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

class Snowflake {
  double x = Random().nextDouble();
  double y = Random().nextDouble();
  double speed = 0.002 + Random().nextDouble() * 0.005;
  double size = 2 + Random().nextDouble() * 4;
}

class SnowflakePainter extends CustomPainter {
  final List<Snowflake> snowflakes;
  final double animationValue;
  SnowflakePainter(this.snowflakes, this.animationValue);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = const Color(0xFF00E5FF).withOpacity(0.6);
    for (var flake in snowflakes) {
      flake.y += flake.speed;
      if (flake.y > 1.0) flake.y = 0.0;
      canvas.drawCircle(Offset(flake.x * size.width, flake.y * size.height), flake.size, paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}