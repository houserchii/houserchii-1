import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

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
  double targetTemp = 22.0;
  double currentRoomTemp = 24.5;
  
  // ⚡ По подразбиране е ИЗКЛЮЧЕНО
  bool isPowerOn = false; 

  // Външни данни от мрежата / локация
  double externalTemp = 28.0;
  int externalHumidity = 40;

  // Час и дата в реално време
  Timer? _clockTimer;
  String _currentTime = '';
  String _currentDate = '';

  // Текущо активни настройки на релето (в секунди)
  int activeWorkSeconds = 240; // 4 мин
  int activeRestSeconds = 180; // 3 мин

  // Избрани нови настройки от слайдърите (в секунди)
  int pendingWorkSeconds = 240;
  int pendingRestSeconds = 180;

  // Флаг дали настройките са променени и чакат следващ цикъл
  bool hasPendingChanges = false;

  // Логика за цикли
  bool isCompressorRunning = false;
  int remainingSeconds = 240;
  Timer? _cycleTimer;

  // Падащо меню за настройки
  bool isSettingsExpanded = false;

  // Анимация за снежинки
  late AnimationController _snowflakeController;
  final List<Snowflake> _snowflakes = List.generate(20, (index) => Snowflake());

  @override
  void initState() {
    super.initState();
    _updateDateTime();

    // Обновяване на часовника всяка секунда
    _clockTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      _updateDateTime();
    });

    _startCompressorCycle();

    _snowflakeController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 10),
    )..repeat();
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
    _snowflakeController.dispose();
    super.dispose();
  }

  void _startCompressorCycle() {
    _cycleTimer?.cancel();

    _cycleTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!isPowerOn) return;

      setState(() {
        if (remainingSeconds > 0) {
          remainingSeconds--;
        } else {
          // При приключване на цикъла прилагаме новите настройки, ако има промяна
          activeWorkSeconds = pendingWorkSeconds;
          activeRestSeconds = pendingRestSeconds;
          hasPendingChanges = false;

          // Смяна на цикъла (работа <-> почивка)
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
          // Background Gradient
          Container(
            decoration: const BoxDecoration(
              gradient: RadialGradient(
                center: Alignment(0, -0.3),
                radius: 1.3,
                colors: [Color(0xFF182232), Color(0xFF07090E)],
              ),
            ),
          ),

          // ❄️ Падащи снежинки (когато е включено)
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

          // Main Content
          SafeArea(
            child: SingleChildScrollView(
              physics: const BouncingScrollPhysics(),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20.0, vertical: 12.0),
                child: Column(
                  children: [
                    // 🌐 ПАНЕЛ: Дата, Час и Мрежова прогноза
                    _buildNetworkHeader(),

                    const SizedBox(height: 16),

                    // 🔝 Главна заглавна лента
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Климатизация',
                              style: TextStyle(
                                fontSize: 24,
                                fontWeight: FontWeight.bold,
                                color: Colors.white,
                              ),
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
                                    boxShadow: [
                                      BoxShadow(
                                        color: isPowerOn ? const Color(0xFF00E5FF) : Colors.redAccent,
                                        blurRadius: 8,
                                        spreadRadius: 1,
                                      )
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  isPowerOn ? 'АКТИВЕН' : 'ИЗКЛЮЧЕН',
                                  style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.grey[400],
                                    letterSpacing: 1.0,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                        _buildPowerButton(),
                      ],
                    ),

                    const SizedBox(height: 15),

                    // 🎛️ Въртящо се колело (Thermostat Wheel)
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
                          AnimatedContainer(
                            duration: const Duration(milliseconds: 300),
                            width: 220,
                            height: 220,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              boxShadow: [
                                BoxShadow(
                                  color: isPowerOn ? const Color(0xFF00E5FF).withOpacity(0.2) : Colors.transparent,
                                  blurRadius: 60,
                                  spreadRadius: 10,
                                )
                              ],
                            ),
                          ),
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
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black54,
                                  blurRadius: 15,
                                  offset: Offset(0, 8),
                                )
                              ],
                            ),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Text(
                                  'СТАЙНА ${currentRoomTemp.toStringAsFixed(1)}°C',
                                  style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.grey[500],
                                    letterSpacing: 1.2,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      targetTemp.toStringAsFixed(1),
                                      style: TextStyle(
                                        fontSize: 44,
                                        fontWeight: FontWeight.w900,
                                        color: isPowerOn ? Colors.white : Colors.grey[700],
                                        height: 1,
                                      ),
                                    ),
                                    Text(
                                      '°C',
                                      style: TextStyle(
                                        fontSize: 18,
                                        fontWeight: FontWeight.bold,
                                        color: isPowerOn ? const Color(0xFF00E5FF) : Colors.grey[700],
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 6),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                                  decoration: BoxDecoration(
                                    color: isPowerOn ? const Color(0xFF00E5FF).withOpacity(0.1) : Colors.white10,
                                    borderRadius: BorderRadius.circular(15),
                                    border: Border.all(
                                      color: isPowerOn ? const Color(0xFF00E5FF).withOpacity(0.3) : Colors.transparent,
                                    ),
                                  ),
                                  child: Text(
                                    'ПЛЪЗНИ ЗА РЕГУЛАЦИЯ',
                                    style: TextStyle(
                                      fontSize: 8,
                                      fontWeight: FontWeight.bold,
                                      color: isPowerOn ? const Color(0xFF00E5FF) : Colors.grey[600],
                                      letterSpacing: 1.0,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 15),

                    // ➕ / ➖ Бутони
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        _buildCircleControlBtn(
                          icon: Icons.remove_rounded,
                          onTap: isPowerOn
                              ? () => setState(() {
                                    if (targetTemp > 16.0) targetTemp -= 0.5;
                                  })
                              : null,
                        ),
                        const SizedBox(width: 30),
                        _buildCircleControlBtn(
                          icon: Icons.add_rounded,
                          onTap: isPowerOn
                              ? () => setState(() {
                                    if (targetTemp < 30.0) targetTemp += 0.5;
                                  })
                              : null,
                          isPrimary: true,
                        ),
                      ],
                    ),

                    const SizedBox(height: 20),

                    // ⏱️ Панел за Таймер на Релето (Жив брояч)
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.04),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: isPowerOn
                              ? (isCompressorRunning
                                  ? const Color(0xFF00E5FF).withOpacity(0.4)
                                  : Colors.orangeAccent.withOpacity(0.4))
                              : Colors.white10,
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Row(
                                children: [
                                  Icon(
                                    !isPowerOn
                                        ? Icons.power_settings_new
                                        : (isCompressorRunning ? Icons.play_circle_fill : Icons.pause_circle_filled),
                                    size: 20,
                                    color: !isPowerOn
                                        ? Colors.grey
                                        : (isCompressorRunning ? const Color(0xFF00E5FF) : Colors.orangeAccent),
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    !isPowerOn
                                        ? 'Компресор: В ОЧАКВАНЕ'
                                        : (isCompressorRunning ? 'Компресор: РАБОТА' : 'Компресор: ПОЧИВКА'),
                                    style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.bold,
                                      color: !isPowerOn
                                          ? Colors.grey
                                          : (isCompressorRunning ? const Color(0xFF00E5FF) : Colors.orangeAccent),
                                    ),
                                  ),
                                ],
                              ),
                              Text(
                                isPowerOn ? _formatTime(remainingSeconds) : '--:--',
                                style: TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.w900,
                                  color: !isPowerOn
                                      ? Colors.grey
                                      : (isCompressorRunning ? const Color(0xFF00E5FF) : Colors.orangeAccent),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                'Текущ цикъл: ${_formatTime(activeWorkSeconds)} работа / ${_formatTime(activeRestSeconds)} почивка',
                                style: const TextStyle(fontSize: 11, color: Colors.white54),
                              ),
                            ],
                          ),
                          if (hasPendingChanges) ...[
                            const SizedBox(height: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                color: Colors.amber.withOpacity(0.15),
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(color: Colors.amber.withOpacity(0.3)),
                              ),
                              child: Row(
                                children: [
                                  const Icon(Icons.hourglass_top_rounded, size: 12, color: Colors.amber),
                                  const SizedBox(width: 6),
                                  Expanded(
                                    child: Text(
                                      'Новите настройки (${_formatTime(pendingWorkSeconds)} / ${_formatTime(pendingRestSeconds)}) ще влязат в сила след този цикъл!',
                                      style: const TextStyle(fontSize: 10, color: Colors.amber, fontWeight: FontWeight.bold),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),

                    const SizedBox(height: 16),

                    // 🎛️ Лента с бутони: ОХЛАЖДАНЕ и НАСТРОЙКА
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(4),
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.04),
                        borderRadius: BorderRadius.circular(25),
                        border: Border.all(color: Colors.white.withOpacity(0.08)),
                      ),
                      child: Row(
                        children: [
                          // ОХЛАЖДАНЕ
                          Expanded(
                            child: Container(
                              padding: const EdgeInsets.symmetric(vertical: 12),
                              decoration: BoxDecoration(
                                color: isPowerOn ? const Color(0xFF00E5FF) : Colors.white10,
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(Icons.ac_unit_rounded, size: 16, color: isPowerOn ? Colors.black : Colors.grey),
                                  const SizedBox(width: 6),
                                  Text(
                                    'ОХЛАЖДАНЕ',
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.bold,
                                      color: isPowerOn ? Colors.black : Colors.grey,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),

                          // НАСТРОЙКА (Колело)
                          Expanded(
                            child: GestureDetector(
                              onTap: () {
                                setState(() {
                                  isSettingsExpanded = !isSettingsExpanded;
                                });
                              },
                              child: Container(
                                padding: const EdgeInsets.symmetric(vertical: 12),
                                decoration: BoxDecoration(
                                  color: isSettingsExpanded ? Colors.white.withOpacity(0.15) : Colors.transparent,
                                  borderRadius: BorderRadius.circular(20),
                                ),
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Icon(
                                      Icons.settings_suggest_rounded,
                                      size: 18,
                                      color: isSettingsExpanded ? const Color(0xFF00E5FF) : Colors.grey[300],
                                    ),
                                    const SizedBox(width: 6),
                                    Text(
                                      'НАСТРОЙКА',
                                      style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.bold,
                                        color: isSettingsExpanded ? const Color(0xFF00E5FF) : Colors.grey[300],
                                      ),
                                    ),
                                    Icon(
                                      isSettingsExpanded ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
                                      size: 18,
                                      color: isSettingsExpanded ? const Color(0xFF00E5FF) : Colors.grey[400],
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),

                    // ⚙️ Падащ панел с настройки (Слайдъри до секунди)
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
                            const Row(
                              children: [
                                Icon(Icons.tune_rounded, size: 18, color: Color(0xFF00E5FF)),
                                SizedBox(width: 8),
                                Text(
                                  'Настройки на таймера за релето',
                                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.white),
                                ),
                              ],
                            ),
                            const Divider(color: Colors.white10, height: 20),

                            // Слайдър за Време за Работа
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                const Text('Време за Работа:', style: TextStyle(fontSize: 12, color: Colors.white70)),
                                Text(
                                  '${_formatTime(pendingWorkSeconds)} мин.',
                                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Color(0xFF00E5FF)),
                                ),
                              ],
                            ),
                            SliderTheme(
                              data: SliderTheme.of(context).copyWith(
                                activeTrackColor: const Color(0xFF00E5FF),
                                thumbColor: const Color(0xFF00E5FF),
                                overlayColor: const Color(0xFF00E5FF).withOpacity(0.2),
                              ),
                              child: Slider(
                                value: pendingWorkSeconds.toDouble(),
                                min: 10,
                                max: 900,
                                divisions: 178,
                                onChanged: (val) {
                                  setState(() {
                                    pendingWorkSeconds = val.round();
                                    hasPendingChanges = (pendingWorkSeconds != activeWorkSeconds || pendingRestSeconds != activeRestSeconds);
                                  });
                                },
                              ),
                            ),

                            const SizedBox(height: 8),

                            // Слайдър за Време за Почивка
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                const Text('Време за Почивка:', style: TextStyle(fontSize: 12, color: Colors.white70)),
                                Text(
                                  '${_formatTime(pendingRestSeconds)} мин.',
                                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.orangeAccent),
                                ),
                              ],
                            ),
                            SliderTheme(
                              data: SliderTheme.of(context).copyWith(
                                activeTrackColor: Colors.orangeAccent,
                                thumbColor: Colors.orangeAccent,
                                overlayColor: Colors.orangeAccent.withOpacity(0.2),
                              ),
                              child: Slider(
                                value: pendingRestSeconds.toDouble(),
                                min: 10,
                                max: 900,
                                divisions: 178,
                                onChanged: (val) {
                                  setState(() {
                                    pendingRestSeconds = val.round();
                                    hasPendingChanges = (pendingWorkSeconds != activeWorkSeconds || pendingRestSeconds != activeRestSeconds);
                                  });
                                },
                              ),
                            ),

                            const SizedBox(height: 8),
                            // Оправено fontStyle: FontStyle.italic
                            Text(
                              '* Плъзни слайдърите за точност до секунди. Новите стойности ще се задействат автоматично, когато текущото отброяване завърши.',
                              style: TextStyle(fontSize: 10, color: Colors.grey[500], fontStyle: FontStyle.italic),
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

  // 🌐 Нов Виджет: Горният Панел за Дата, Час и Локална Температура
  Widget _buildNetworkHeader() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF131A28),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withOpacity(0.08)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              const Icon(Icons.access_time_filled_rounded, size: 18, color: Color(0xFF00E5FF)),
              const SizedBox(width: 8),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _currentTime.isEmpty ? '00:00:00' : _currentTime,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                      letterSpacing: 0.8,
                    ),
                  ),
                  Text(
                    _currentDate,
                    style: TextStyle(fontSize: 10, color: Colors.grey[400]),
                  ),
                ],
              ),
            ],
          ),
          Row(
            children: [
              const Icon(Icons.wb_sunny_rounded, color: Colors.amber, size: 18),
              const SizedBox(width: 4),
              Text(
                '$externalTemp°C',
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Colors.white),
              ),
              const SizedBox(width: 12),
              const Icon(Icons.water_drop_rounded, color: Color(0xFF00E5FF), size: 16),
              const SizedBox(width: 4),
              Text(
                '$externalHumidity%',
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Colors.white),
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
          if (isPowerOn) {
            isCompressorRunning = true;
            remainingSeconds = activeWorkSeconds;
          }
        });
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        width: 48,
        height: 48,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: isPowerOn ? const Color(0xFF00E5FF) : Colors.white.withOpacity(0.05),
          boxShadow: [
            if (isPowerOn)
              BoxShadow(
                color: const Color(0xFF00E5FF).withOpacity(0.4),
                blurRadius: 12,
                spreadRadius: 1,
              )
          ],
        ),
        child: Icon(
          Icons.power_settings_new_rounded,
          color: isPowerOn ? Colors.black : Colors.white70,
          size: 24,
        ),
      ),
    );
  }

  Widget _buildCircleControlBtn({required IconData icon, VoidCallback? onTap, bool isPrimary = false}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 56,
        height: 56,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: isPrimary ? const Color(0xFF00E5FF).withOpacity(0.15) : Colors.white.withOpacity(0.04),
          border: Border.all(
            color: isPrimary ? const Color(0xFF00E5FF) : Colors.white.withOpacity(0.1),
            width: 1.5,
          ),
        ),
        child: Icon(
          icon,
          color: isPowerOn ? (isPrimary ? const Color(0xFF00E5FF) : Colors.white) : Colors.grey[700],
          size: 28,
        ),
      ),
    );
  }
}

// 🎨 Рисувател за Колелото
class WheelPainter extends CustomPainter {
  final double progress;
  final bool isActive;

  WheelPainter({required this.progress, required this.isActive});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - 10;

    final bgPaint = Paint()
      ..color = Colors.white.withOpacity(0.08)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 8;

    final activePaint = Paint()
      ..color = isActive ? const Color(0xFF00E5FF) : Colors.grey[800]!
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 10;

    canvas.drawCircle(center, radius, bgPaint);

    double sweepAngle = 2 * pi * progress;
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      -pi / 2,
      sweepAngle,
      false,
      activePaint,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

// ❄️ Модел за Снежинка
class Snowflake {
  double x = Random().nextDouble();
  double y = Random().nextDouble();
  double size = Random().nextDouble() * 4 + 2;
  double speed = Random().nextDouble() * 0.2 + 0.1;
}

// ❄️ Рисувател за падащи снежинки
class SnowflakePainter extends CustomPainter {
  final List<Snowflake> snowflakes;
  final double animationValue;

  SnowflakePainter(this.snowflakes, this.animationValue);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xFF00E5FF).withOpacity(0.3)
      ..style = PaintingStyle.fill;

    for (var flake in snowflakes) {
      double currentY = (flake.y + animationValue * flake.speed) % 1.0;
      canvas.drawCircle(
        Offset(flake.x * size.width, currentY * size.height),
        flake.size,
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}