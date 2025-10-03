import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:hive/hive.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

const String kDoseBoxName = 'doses';
const String kNotificationChannelId = 'med_channel';
const String kNotificationChannelName = 'Medicine Reminders';
const String kNotificationChannelDescription = 'Weekly tablet reminders';
const String kTtsMessage = 'Please take your tablets now.';

final FlutterLocalNotificationsPlugin _notifications = FlutterLocalNotificationsPlugin();
final FlutterTts _tts = FlutterTts();
bool _speakOnLaunch = false;
bool _androidCustomSoundAvailable = true;
NotificationDetails _buildNotificationDetails() => NotificationDetails(
      android: AndroidNotificationDetails(
        kNotificationChannelId,
        kNotificationChannelName,
        channelDescription: kNotificationChannelDescription,
        importance: Importance.max,
        priority: Priority.high,
        playSound: true,
        sound: _androidCustomSoundAvailable ? const RawResourceAndroidNotificationSound('tablet_time') : null,
        enableLights: true,
        enableVibration: true,
        icon: '@mipmap/ic_launcher',
      ),
      iOS: const DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
        // For a bundled custom sound on iOS add: sound: 'tablet_time.wav'.
      ),
    );

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Hive.initFlutter();
  if (!Hive.isAdapterRegistered(1)) {
    Hive.registerAdapter(DoseAdapter());
  }
  await Hive.openBox<Dose>(kDoseBoxName);

  await _bootstrapTts();
  await _configureLocalTimeZone();
  await _initializeNotifications();

  final details = await _notifications.getNotificationAppLaunchDetails();
  _speakOnLaunch = details?.didNotificationLaunchApp ?? false;

  await scheduleAll();

  runApp(const TabletReminderApp());
}

Future<void> _bootstrapTts() async {
  await _tts.awaitSpeakCompletion(true);
  await _tts.setLanguage('en-US');
  await _tts.setSpeechRate(0.45);
  await _tts.setVolume(1.0);
  await _tts.setPitch(1.0);
  if (Platform.isIOS) {
    await _tts.setSharedInstance(true);
  }
}

Future<void> _configureLocalTimeZone() async {
  tzdata.initializeTimeZones();
  final now = DateTime.now();
  final abbreviation = now.timeZoneName;
  final offset = now.timeZoneOffset;

  tz.Location? location;
  final mapped = _abbrToTimezone[abbreviation];
  if (mapped != null) {
    try {
      location = tz.getLocation(mapped);
    } catch (_) {
      location = null;
    }
  }

  location ??= _findLocationByOffset(offset) ?? tz.getLocation('UTC');
  tz.setLocalLocation(location);
}

tz.Location? _findLocationByOffset(Duration offset) {
  for (final entry in tz.timeZoneDatabase.locations.entries) {
    final tzDate = tz.TZDateTime.now(entry.value);
    if (tzDate.timeZoneOffset == offset) {
      return entry.value;
    }
  }
  return null;
}

Future<void> _initializeNotifications() async {
  const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
  const darwinInit = DarwinInitializationSettings(
    requestAlertPermission: true,
    requestBadgePermission: true,
    requestSoundPermission: true,
  );
  const settings = InitializationSettings(android: androidInit, iOS: darwinInit);

  await _notifications.initialize(
    settings,
    onDidReceiveNotificationResponse: _onNotificationResponse,
  );

  final androidPlugin =
      _notifications.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
  if (androidPlugin != null) {
    await androidPlugin.requestNotificationsPermission();
    try {
      await androidPlugin.createNotificationChannel(
        const AndroidNotificationChannel(
          kNotificationChannelId,
          kNotificationChannelName,
          description: kNotificationChannelDescription,
          importance: Importance.max,
          playSound: true,
          sound: RawResourceAndroidNotificationSound('tablet_time'),
          audioAttributesUsage: AudioAttributesUsage.alarm,
        ),
      );
    } on PlatformException {
      _androidCustomSoundAvailable = false;
      await androidPlugin.createNotificationChannel(
        const AndroidNotificationChannel(
          kNotificationChannelId,
          kNotificationChannelName,
          description: kNotificationChannelDescription,
          importance: Importance.max,
          playSound: true,
        ),
      );
    }
  }

  final iosPlugin =
      _notifications.resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>();
  await iosPlugin?.requestPermissions(alert: true, badge: true, sound: true);
}

void _onNotificationResponse(NotificationResponse response) {
  _triggerReminderSpeech();
}

Future<void> _triggerReminderSpeech() async {
  try {
    await _tts.stop();
  } catch (_) {}
  await _tts.speak(kTtsMessage);
}


Future<void> previewReminderSound() async {
  try {
    await _notifications.show(
      9990000,
      'Tablet Reminder',
      'This is how the reminder alarm will sound.',
      _buildNotificationDetails(),
    );
  } on PlatformException {
    _androidCustomSoundAvailable = false;
    await _notifications.show(
      9990000,
      'Tablet Reminder',
      'This is how the reminder alarm will sound.',
      _buildNotificationDetails(),
    );
  }
}

Future<void> scheduleAll() async {
  final box = Hive.box<Dose>(kDoseBoxName);
  await _notifications.cancelAll();

  for (final entry in box.toMap().entries) {
    final int doseKey = entry.key as int;
    final Dose dose = entry.value;
    if (!dose.isActive || dose.weekdays.isEmpty) {
      continue;
    }

    final sortedWeekdays = [...dose.weekdays]..sort();
    for (final weekday in sortedWeekdays) {
      final tz.TZDateTime scheduled = _nextInstanceOfWeekday(weekday, dose.hour, dose.minute);
      final notificationId = _notificationIdFor(doseKey, weekday);
      final dayLabel = _weekdayLabels[weekday] ?? 'Day';
      final body = '${dose.dosage} - $dayLabel at ${_formatTime(dose.hour, dose.minute)}';

      final details = _buildNotificationDetails();
      try {
        await _notifications.zonedSchedule(
          notificationId,
          dose.name,
          body,
          scheduled,
          details,
          androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
          uiLocalNotificationDateInterpretation: UILocalNotificationDateInterpretation.absoluteTime,
          matchDateTimeComponents: DateTimeComponents.dayOfWeekAndTime,
          payload: doseKey.toString(),
        );
      } on PlatformException {
        _androidCustomSoundAvailable = false;
        await _notifications.zonedSchedule(
          notificationId,
          dose.name,
          body,
          scheduled,
          _buildNotificationDetails(),
          androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
          uiLocalNotificationDateInterpretation: UILocalNotificationDateInterpretation.absoluteTime,
          matchDateTimeComponents: DateTimeComponents.dayOfWeekAndTime,
          payload: doseKey.toString(),
        );
      }
    }
  }
}

tz.TZDateTime _nextInstanceOfWeekday(int weekday, int hour, int minute) {
  final now = tz.TZDateTime.now(tz.local);
  var scheduled = tz.TZDateTime(tz.local, now.year, now.month, now.day, hour, minute);

  while (scheduled.weekday != weekday || !scheduled.isAfter(now)) {
    final nextDay = scheduled.add(const Duration(days: 1));
    scheduled = tz.TZDateTime(tz.local, nextDay.year, nextDay.month, nextDay.day, hour, minute);
  }

  return scheduled;
}

int _notificationIdFor(int doseKey, int weekday) => doseKey * 10 + weekday;

String _formatTime(int hour, int minute) {
  String twoDigit(int value) => value.toString().padLeft(2, '0');
  return '${twoDigit(hour)}:${twoDigit(minute)}';
}

String _formatWeekdays(List<int> weekdays) {
  final sorted = [...weekdays]..sort();
  return sorted.map((w) => _weekdayLabels[w] ?? 'Day').join(', ');
}

const Map<int, String> _weekdayLabels = {
  1: 'Mon',
  2: 'Tue',
  3: 'Wed',
  4: 'Thu',
  5: 'Fri',
  6: 'Sat',
  7: 'Sun',
};

const Map<String, String> _abbrToTimezone = {
  'UTC': 'UTC',
  'GMT': 'Etc/GMT',
  'BST': 'Europe/London',
  'IST': 'Asia/Kolkata',
  'WET': 'Europe/Lisbon',
  'CET': 'Europe/Paris',
  'CEST': 'Europe/Paris',
  'EET': 'Europe/Athens',
  'EEST': 'Europe/Athens',
  'MSK': 'Europe/Moscow',
  'AST': 'America/Halifax',
  'ADT': 'America/Halifax',
  'EST': 'America/New_York',
  'EDT': 'America/New_York',
  'CST': 'America/Chicago',
  'CDT': 'America/Chicago',
  'MST': 'America/Denver',
  'MDT': 'America/Denver',
  'PST': 'America/Los_Angeles',
  'PDT': 'America/Los_Angeles',
  'HST': 'Pacific/Honolulu',
  'AKST': 'America/Anchorage',
  'AKDT': 'America/Anchorage',
  'AEST': 'Australia/Sydney',
  'AEDT': 'Australia/Sydney',
  'ACST': 'Australia/Adelaide',
  'ACDT': 'Australia/Adelaide',
  'AWST': 'Australia/Perth',
  'NZST': 'Pacific/Auckland',
  'NZDT': 'Pacific/Auckland',
};

class TabletReminderApp extends StatefulWidget {
  const TabletReminderApp({super.key});

  @override
  State<TabletReminderApp> createState() => _TabletReminderAppState();
}

class _TabletReminderAppState extends State<TabletReminderApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (_speakOnLaunch) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        _speakOnLaunch = false;
        await _triggerReminderSpeech();
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      scheduleAll();
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Tablet Reminder',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
      ),
      home: const DoseListPage(),
    );
  }
}

class DoseListPage extends StatelessWidget {
  const DoseListPage({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Box<Dose>>(
      valueListenable: Hive.box<Dose>(kDoseBoxName).listenable(),
      builder: (context, box, _) {
        final entries = box.toMap().entries.toList()
          ..sort((a, b) => (a.key as int).compareTo(b.key as int));
        return Scaffold(
          appBar: AppBar(
            title: const Text('Tablet Reminder'),
          ),
          body: entries.isEmpty
              ? const _EmptyState()
              : ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: entries.length,
                  itemBuilder: (context, index) {
                    final entry = entries[index];
                    final key = entry.key as int;
                    final dose = entry.value;
                    return _DoseCard(
                      doseKey: key,
                      dose: dose,
                    );
                  },
                ),
          floatingActionButton: FloatingActionButton(
            onPressed: () async {
              await Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const DoseFormPage()),
              );
              await scheduleAll();
            },
            child: const Icon(Icons.add),
          ),
        );
      },
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: const [
          Icon(Icons.medication_outlined, size: 72, color: Colors.grey),
          SizedBox(height: 16),
          Text('No reminders yet', style: TextStyle(fontSize: 20)),
          SizedBox(height: 8),
          Text('Tap + to add your first tablet reminder.'),
        ],
      ),
    );
  }
}

class _DoseCard extends StatelessWidget {
  const _DoseCard({required this.doseKey, required this.dose});

  final int doseKey;
  final Dose dose;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: ListTile(
        onTap: () async {
          await Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => DoseFormPage(doseKey: doseKey, existingDose: dose),
            ),
          );
          await scheduleAll();
        },
        title: Text(dose.name, style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text(
          '${dose.dosage} - ${_formatWeekdays(dose.weekdays)} - ${_formatTime(dose.hour, dose.minute)}',
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Switch(
              value: dose.isActive,
              onChanged: (value) async {
                dose.isActive = value;
                await dose.save();
                await scheduleAll();
              },
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline),
              onPressed: () => _confirmDelete(context),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmDelete(BuildContext context) async {
    final shouldDelete = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete reminder?'),
        content: Text('Remove ${dose.name}? This cancels scheduled alarms.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (shouldDelete == true) {
      await dose.delete();
      await scheduleAll();
    }
  }
}

class DoseFormPage extends StatefulWidget {
  const DoseFormPage({super.key, this.doseKey, this.existingDose});

  final int? doseKey;
  final Dose? existingDose;

  @override
  State<DoseFormPage> createState() => _DoseFormPageState();
}

class _DoseFormPageState extends State<DoseFormPage> {
  late final TextEditingController _nameController;
  late final TextEditingController _dosageController;
  late TimeOfDay _selectedTime;
  late final Set<int> _selectedWeekdays;

  @override
  void initState() {
    super.initState();
    final dose = widget.existingDose;
    _nameController = TextEditingController(text: dose?.name ?? '');
    _dosageController = TextEditingController(text: dose?.dosage ?? '1 tablet');
    _selectedTime = dose?.timeOfDay ?? const TimeOfDay(hour: 9, minute: 0);
    _selectedWeekdays = {...(dose?.weekdays ?? const [1, 2, 3, 4, 5])};
  }

  @override
  void dispose() {
    _nameController.dispose();
    _dosageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isEditing = widget.existingDose != null;
    return Scaffold(
      appBar: AppBar(
        title: Text(isEditing ? 'Edit reminder' : 'Add reminder'),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _nameController,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(
                  labelText: 'Medicine name',
                  hintText: 'e.g. Vitamin D',
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _dosageController,
                decoration: const InputDecoration(
                  labelText: 'Dosage',
                  hintText: 'e.g. 1 tablet',
                ),
              ),
              const SizedBox(height: 24),
              Text('Time', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              FilledButton.tonal(
                onPressed: _pickTime,
                child: Text(_formatTime(_selectedTime.hour, _selectedTime.minute)),
              ),
              const SizedBox(height: 24),
              Text('Weekdays', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: List.generate(7, (index) {
                  final weekday = index + 1;
                  final label = _weekdayLabels[weekday] ?? 'Day';
                  final selected = _selectedWeekdays.contains(weekday);
                  return ChoiceChip(
                    label: Text(label),
                    selected: selected,
                    onSelected: (_) {
                      setState(() {
                        if (selected) {
                          _selectedWeekdays.remove(weekday);
                        } else {
                          _selectedWeekdays.add(weekday);
                        }
                      });
                    },
                  );
                }),
              ),
              const SizedBox(height: 24),
              Text('Preview', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _previewSound,
                      icon: const Icon(Icons.notifications_active_outlined),
                      label: const Text('Preview sound'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _previewVoice,
                      icon: const Icon(Icons.record_voice_over_outlined),
                      label: const Text('Preview voice'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 32),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _save,
                  child: Text(isEditing ? 'Save changes' : 'Save reminder'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }



  Future<void> _pickTime() async {
    final picked = await showTimePicker(context: context, initialTime: _selectedTime);
    if (picked != null) {
      setState(() => _selectedTime = picked);
    }
  }

  Future<void> _previewSound() async {
    await previewReminderSound();
  }

  Future<void> _previewVoice() async {
    await _triggerReminderSpeech();
  }

  Future<void> _save() async {
    final name = _nameController.text.trim();
    final dosage = _dosageController.text.trim();

    if (name.isEmpty) {
      _showError('Please enter a medicine name.');
      return;
    }
    if (dosage.isEmpty) {
      _showError('Please enter a dosage.');
      return;
    }
    if (_selectedWeekdays.isEmpty) {
      _showError('Select at least one weekday.');
      return;
    }

    final sortedWeekdays = _selectedWeekdays.toList()..sort();
    final dose = Dose(
      name: name,
      dosage: dosage,
      hour: _selectedTime.hour,
      minute: _selectedTime.minute,
      weekdays: sortedWeekdays,
      isActive: widget.existingDose?.isActive ?? true,
    );

    final box = Hive.box<Dose>(kDoseBoxName);
    if (widget.doseKey != null) {
      await box.put(widget.doseKey, dose);
    } else {
      await box.add(dose);
    }

    if (!mounted) return;
    Navigator.of(context).pop();
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }
}

@HiveType(typeId: 1)
class Dose extends HiveObject {
  Dose({
    required this.name,
    required this.dosage,
    required this.hour,
    required this.minute,
    required this.weekdays,
    required this.isActive,
  });

  @HiveField(0)
  String name;

  @HiveField(1)
  String dosage;

  @HiveField(2)
  int hour;

  @HiveField(3)
  int minute;

  @HiveField(4)
  List<int> weekdays;

  @HiveField(5)
  bool isActive;

  TimeOfDay get timeOfDay => TimeOfDay(hour: hour, minute: minute);
}

class DoseAdapter extends TypeAdapter<Dose> {
  @override
  final int typeId = 1;

  @override
  Dose read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{};
    for (var i = 0; i < numOfFields; i++) {
      final field = reader.readByte();
      fields[field] = reader.read();
    }
    return Dose(
      name: fields[0] as String,
      dosage: fields[1] as String,
      hour: fields[2] as int,
      minute: fields[3] as int,
      weekdays: List<int>.from(fields[4] as List<dynamic>),
      isActive: (fields[5] as bool?) ?? true,
    );
  }

  @override
  void write(BinaryWriter writer, Dose obj) {
    writer
      ..writeByte(6)
      ..writeByte(0)
      ..write(obj.name)
      ..writeByte(1)
      ..write(obj.dosage)
      ..writeByte(2)
      ..write(obj.hour)
      ..writeByte(3)
      ..write(obj.minute)
      ..writeByte(4)
      ..write(obj.weekdays)
      ..writeByte(5)
      ..write(obj.isActive);
  }
}

/*
README
- Place tablet_time.wav into android/app/src/main/res/raw/.
- Run: flutter pub get && flutter run
- Note for Android 12+: exact alarms require manual toggle in App Info.
*/
