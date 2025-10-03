import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:hive/hive.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:timezone/timezone.dart' as tz;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Hive.initFlutter();
  if (!Hive.isAdapterRegistered(DoseAdapter.kTypeId)) {
    Hive.registerAdapter(DoseAdapter());
  }

  tz.initializeTimeZones();
  try {
    final String localName = DateTime.now().timeZoneName;
    tz.setLocalLocation(tz.getLocation(localName));
  } catch (_) {
    tz.setLocalLocation(tz.UTC);
  }

  final FlutterLocalNotificationsPlugin notificationsPlugin =
      FlutterLocalNotificationsPlugin();
  final FlutterTts flutterTts = FlutterTts();
  await _initializeTts(flutterTts);
  await _initializeNotifications(notificationsPlugin, flutterTts);

  final Box<Dose> doseBox = await Hive.openBox<Dose>('doses');
  final DoseNotificationScheduler scheduler =
      DoseNotificationScheduler(notificationsPlugin, flutterTts);
  await scheduler.rescheduleAll(doseBox);

  runApp(HealthReminderApp(
    doseBox: doseBox,
    scheduler: scheduler,
  ));
}

Future<void> _initializeTts(FlutterTts flutterTts) async {
  await flutterTts.setLanguage('en-US');
  await flutterTts.setSpeechRate(0.5);
  await flutterTts.awaitSpeakCompletion(true);
}

Future<void> _initializeNotifications(
  FlutterLocalNotificationsPlugin plugin,
  FlutterTts flutterTts,
) async {
  const AndroidInitializationSettings androidInitializationSettings =
      AndroidInitializationSettings('@mipmap/ic_launcher');
  const DarwinInitializationSettings iosInitializationSettings =
      DarwinInitializationSettings();

  final InitializationSettings initializationSettings =
      const InitializationSettings(
    android: androidInitializationSettings,
    iOS: iosInitializationSettings,
  );

  final NotificationAppLaunchDetails? launchDetails =
      await plugin.getNotificationAppLaunchDetails();

  await plugin.initialize(
    initializationSettings,
    onDidReceiveNotificationResponse: (NotificationResponse response) {
      DoseNotificationScheduler.invokeTts(flutterTts);
    },
    onDidReceiveBackgroundNotificationResponse:
        DoseNotificationScheduler.onBackgroundNotificationResponse,
  );

  final AndroidFlutterLocalNotificationsPlugin? androidImplementation =
      plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
  await androidImplementation?.requestNotificationsPermission();
  await androidImplementation?.requestExactAlarmsPermission();

  final IOSFlutterLocalNotificationsPlugin? iosImplementation =
      plugin.resolvePlatformSpecificImplementation<
          IOSFlutterLocalNotificationsPlugin>();
  await iosImplementation?.requestPermissions(
    alert: true,
    badge: true,
    sound: true,
  );

  if (launchDetails?.didNotificationLaunchApp ?? false) {
    DoseNotificationScheduler.invokeTts(flutterTts);
  }
}

class HealthReminderApp extends StatelessWidget {
  const HealthReminderApp({
    super.key,
    required this.doseBox,
    required this.scheduler,
  });

  final Box<Dose> doseBox;
  final DoseNotificationScheduler scheduler;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Health Reminder',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: Colors.teal,
        useMaterial3: true,
        brightness: Brightness.light,
      ),
      home: DoseHomePage(
        doseBox: doseBox,
        scheduler: scheduler,
      ),
    );
  }
}

class DoseHomePage extends StatefulWidget {
  const DoseHomePage({
    super.key,
    required this.doseBox,
    required this.scheduler,
  });

  final Box<Dose> doseBox;
  final DoseNotificationScheduler scheduler;

  @override
  State<DoseHomePage> createState() => _DoseHomePageState();
}

class _DoseHomePageState extends State<DoseHomePage>
    with WidgetsBindingObserver {
  static const List<_Weekday> weekdays = <_Weekday>[
    _Weekday(DateTime.monday, 'Mon'),
    _Weekday(DateTime.tuesday, 'Tue'),
    _Weekday(DateTime.wednesday, 'Wed'),
    _Weekday(DateTime.thursday, 'Thu'),
    _Weekday(DateTime.friday, 'Fri'),
    _Weekday(DateTime.saturday, 'Sat'),
    _Weekday(DateTime.sunday, 'Sun'),
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.resumed) {
      unawaited(widget.scheduler.rescheduleAll(widget.doseBox));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Dose reminders'),
        actions: <Widget>[
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Reschedule all reminders',
            onPressed: () {
              unawaited(widget.scheduler.rescheduleAll(widget.doseBox));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Rescheduled reminders')),
              );
            },
          ),
        ],
      ),
      body: ValueListenableBuilder<Box<Dose>>(
        valueListenable: widget.doseBox.listenable(),
        builder: (BuildContext context, Box<Dose> box, _) {
          if (box.isEmpty) {
            return const _EmptyState();
          }

          final List<int> keys = box.keys.cast<int>().toList(growable: false);
          keys.sort();

          return ListView.separated(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
            itemCount: keys.length,
            separatorBuilder: (_, __) => const SizedBox(height: 12),
            itemBuilder: (BuildContext context, int index) {
              final int key = keys[index];
              final Dose? dose = box.get(key);
              if (dose == null) {
                return const SizedBox.shrink();
              }

              return _DoseCard(
                dose: dose,
                onToggle: (bool value) => _toggleDose(key, dose, value),
                onEdit: () => _openDoseForm(initialDose: dose, keyToEdit: key),
                onDelete: () => _deleteDose(key),
              );
            },
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.add),
        label: const Text('Add reminder'),
        onPressed: () => _openDoseForm(),
      ),
    );
  }

  Future<void> _toggleDose(int key, Dose dose, bool isEnabled) async {
    final Dose updated = dose.copyWith(isEnabled: isEnabled);
    await widget.doseBox.put(key, updated);
    if (isEnabled) {
      await widget.scheduler.scheduleDose(key, updated);
    } else {
      await widget.scheduler.cancelDose(key);
    }
  }

  Future<void> _deleteDose(int key) async {
    await widget.doseBox.delete(key);
    await widget.scheduler.cancelDose(key);
  }

  Future<void> _openDoseForm({Dose? initialDose, int? keyToEdit}) async {
    final Dose? result = await showModalBottomSheet<Dose>(
      context: context,
      isScrollControlled: true,
      builder: (BuildContext context) {
        return Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(context).viewInsets.bottom,
          ),
          child: DoseForm(initialDose: initialDose),
        );
      },
    );

    if (result == null) {
      return;
    }

    if (keyToEdit != null) {
      await widget.doseBox.put(keyToEdit, result);
      await widget.scheduler.rescheduleDose(keyToEdit, result);
    } else {
      final int key = await widget.doseBox.add(result);
      await widget.scheduler.scheduleDose(key, result);
    }
  }
}

class _DoseCard extends StatelessWidget {
  const _DoseCard({
    required this.dose,
    required this.onToggle,
    required this.onEdit,
    required this.onDelete,
  });

  final Dose dose;
  final ValueChanged<bool> onToggle;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final MaterialLocalizations localizations =
        MaterialLocalizations.of(context);
    final String timeLabel = localizations.formatTimeOfDay(
      TimeOfDay(hour: dose.hour, minute: dose.minute),
      alwaysUse24HourFormat: MediaQuery.of(context).alwaysUse24HourFormat,
    );
    final String weekdaysLabel = _formatWeekdays(dose.weekdays);

    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      clipBehavior: Clip.antiAlias,
      elevation: 0,
      child: InkWell(
        onTap: onEdit,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      dose.title,
                      style: theme.textTheme.titleMedium,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '$timeLabel · $weekdaysLabel',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    if (dose.notes.isNotEmpty) ...<Widget>[
                      const SizedBox(height: 4),
                      Text(
                        dose.notes,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Switch(
                    value: dose.isEnabled,
                    onChanged: onToggle,
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete_outline),
                    tooltip: 'Delete reminder',
                    onPressed: onDelete,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: const <Widget>[
            Icon(Icons.medication_liquid_outlined, size: 80),
            SizedBox(height: 16),
            Text(
              'No reminders yet',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
              textAlign: TextAlign.center,
            ),
            SizedBox(height: 8),
            Text(
              'Tap “Add reminder” to plan when to take your tablets.',
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

class DoseForm extends StatefulWidget {
  const DoseForm({super.key, this.initialDose});

  final Dose? initialDose;

  @override
  State<DoseForm> createState() => _DoseFormState();
}

class _DoseFormState extends State<DoseForm> {
  late final TextEditingController _titleController;
  late final TextEditingController _notesController;
  late TimeOfDay _timeOfDay;
  late Set<int> _selectedWeekdays;
  bool _isEnabled = true;

  @override
  void initState() {
    super.initState();
    final Dose? dose = widget.initialDose;
    _titleController = TextEditingController(text: dose?.title ?? 'My tablets');
    _notesController = TextEditingController(text: dose?.notes ?? '');
    _timeOfDay = TimeOfDay(hour: dose?.hour ?? 8, minute: dose?.minute ?? 0);
    _selectedWeekdays = Set<int>.from(
      dose?.weekdays ?? <int>[DateTime.monday],
    );
    _isEnabled = dose?.isEnabled ?? true;
  }

  @override
  void dispose() {
    _titleController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final MediaQueryData mediaQuery = MediaQuery.of(context);
    final ThemeData theme = Theme.of(context);

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          24,
          24,
          24,
          24 + mediaQuery.viewInsets.bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
              widget.initialDose == null ? 'New reminder' : 'Edit reminder',
              style: theme.textTheme.titleLarge,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _titleController,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'Reminder title',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _notesController,
              textCapitalization: TextCapitalization.sentences,
              minLines: 1,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: 'Notes (optional)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            _TimePickerField(
              timeOfDay: _timeOfDay,
              onChanged: (TimeOfDay value) {
                setState(() => _timeOfDay = value);
              },
            ),
            const SizedBox(height: 16),
            Text(
              'Weekdays',
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: _DoseHomePageState.weekdays.map((_Weekday day) {
                final bool isSelected = _selectedWeekdays.contains(day.value);
                return FilterChip(
                  label: Text(day.label),
                  selected: isSelected,
                  onSelected: (bool selected) {
                    setState(() {
                      if (selected) {
                        _selectedWeekdays.add(day.value);
                      } else {
                        _selectedWeekdays.remove(day.value);
                      }
                      if (_selectedWeekdays.isEmpty) {
                        _selectedWeekdays.add(day.value);
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text(
                              'Select at least one weekday for reminders.',
                            ),
                          ),
                        );
                      }
                    });
                  },
                );
              }).toList(),
            ),
            const SizedBox(height: 16),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Enable immediately'),
              value: _isEnabled,
              onChanged: (bool value) => setState(() => _isEnabled = value),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              icon: const Icon(Icons.save),
              label: Text(
                widget.initialDose == null ? 'Save reminder' : 'Save changes',
              ),
              onPressed: _saveDose,
            ),
          ],
        ),
      ),
    );
  }

  void _saveDose() {
    final String title = _titleController.text.trim();
    if (title.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please provide a reminder title.')),
      );
      return;
    }

    final Dose dose = Dose(
      title: title,
      notes: _notesController.text.trim(),
      hour: _timeOfDay.hour,
      minute: _timeOfDay.minute,
      weekdays: _selectedWeekdays.toList()..sort(),
      isEnabled: _isEnabled,
    );
    Navigator.of(context).pop(dose);
  }
}

class _TimePickerField extends StatelessWidget {
  const _TimePickerField({
    required this.timeOfDay,
    required this.onChanged,
  });

  final TimeOfDay timeOfDay;
  final ValueChanged<TimeOfDay> onChanged;

  @override
  Widget build(BuildContext context) {
    final MaterialLocalizations localizations =
        MaterialLocalizations.of(context);
    final String label = localizations.formatTimeOfDay(
      timeOfDay,
      alwaysUse24HourFormat: MediaQuery.of(context).alwaysUse24HourFormat,
    );

    return OutlinedButton.icon(
      icon: const Icon(Icons.schedule),
      label: Align(
        alignment: Alignment.centerLeft,
        child: Text('Reminder time: $label'),
      ),
      onPressed: () async {
        final TimeOfDay? picked = await showTimePicker(
          context: context,
          initialTime: timeOfDay,
        );
        if (picked != null) {
          onChanged(picked);
        }
      },
    );
  }
}

String _formatWeekdays(List<int> weekdays) {
  final List<String> labels = _DoseHomePageState.weekdays
      .where((_Weekday day) => weekdays.contains(day.value))
      .map((_Weekday day) => day.label)
      .toList();
  return labels.join(', ');
}

class _Weekday {
  const _Weekday(this.value, this.label);

  final int value;
  final String label;
}

class DoseNotificationScheduler {
  DoseNotificationScheduler(this._plugin, this._tts);

  final FlutterLocalNotificationsPlugin _plugin;
  final FlutterTts _tts;

  static const AndroidNotificationDetails _androidDetails =
      AndroidNotificationDetails(
    'dose_reminder_channel',
    'Dose reminders',
    channelDescription: 'Notifications to remind you about your tablets.',
    importance: Importance.max,
    priority: Priority.high,
  );

  static const DarwinNotificationDetails _iosDetails =
      DarwinNotificationDetails();

  static const NotificationDetails _notificationDetails = NotificationDetails(
    android: _androidDetails,
    iOS: _iosDetails,
  );

  Future<void> scheduleDose(int key, Dose dose) async {
    if (!dose.isEnabled) {
      return;
    }

    await cancelDose(key);
    for (final int weekday in dose.weekdays) {
      await _scheduleForWeekday(key, dose, weekday);
    }
  }

  Future<void> rescheduleDose(int key, Dose dose) async {
    await scheduleDose(key, dose);
  }

  Future<void> rescheduleAll(Box<Dose> box) async {
    for (final dynamic rawKey in box.keys) {
      final int key = rawKey as int;
      final Dose? dose = box.get(key);
      if (dose != null) {
        await scheduleDose(key, dose);
      }
    }
  }

  Future<void> cancelDose(int key) async {
    for (int weekday = DateTime.monday; weekday <= DateTime.sunday; weekday++) {
      await _plugin.cancel(key * 10 + weekday);
    }
  }

  Future<void> _scheduleForWeekday(int key, Dose dose, int weekday) async {
    final tz.TZDateTime scheduledDate = _nextInstanceOfWeekday(
      weekday,
      dose.hour,
      dose.minute,
    );

    await _plugin.zonedSchedule(
      key * 10 + weekday,
      dose.title,
      dose.notes.isEmpty ? 'Please take your tablets now.' : dose.notes,
      scheduledDate,
      _notificationDetails,
      androidAllowWhileIdle: true,
      payload: dose.title,
      uiLocalNotificationDateInterpretation:
          UILocalNotificationDateInterpretation.absoluteTime,
      matchDateTimeComponents: DateTimeComponents.dayOfWeekAndTime,
    );
  }

  tz.TZDateTime _nextInstanceOfWeekday(int weekday, int hour, int minute) {
    tz.TZDateTime scheduledDate = tz.TZDateTime.now(tz.local);
    scheduledDate = tz.TZDateTime(
      tz.local,
      scheduledDate.year,
      scheduledDate.month,
      scheduledDate.day,
      hour,
      minute,
    );

    final tz.TZDateTime now = tz.TZDateTime.now(tz.local);
    while (scheduledDate.weekday != weekday || !scheduledDate.isAfter(now)) {
      scheduledDate = scheduledDate.add(const Duration(days: 1));
    }
    return scheduledDate;
  }

  static void invokeTts(FlutterTts tts) {
    tts.stop();
    tts.speak('Please take your tablets now.');
  }

  @pragma('vm:entry-point')
  static void onBackgroundNotificationResponse(
    NotificationResponse response,
  ) {
    // No background handling required. The tap brings the app to foreground.
  }
}

class Dose {
  const Dose({
    required this.title,
    required this.notes,
    required this.hour,
    required this.minute,
    required this.weekdays,
    required this.isEnabled,
  });

  final String title;
  final String notes;
  final int hour;
  final int minute;
  final List<int> weekdays;
  final bool isEnabled;

  Dose copyWith({
    String? title,
    String? notes,
    int? hour,
    int? minute,
    List<int>? weekdays,
    bool? isEnabled,
  }) {
    return Dose(
      title: title ?? this.title,
      notes: notes ?? this.notes,
      hour: hour ?? this.hour,
      minute: minute ?? this.minute,
      weekdays: weekdays ?? List<int>.from(this.weekdays),
      isEnabled: isEnabled ?? this.isEnabled,
    );
  }
}

class DoseAdapter extends TypeAdapter<Dose> {
  static const int kTypeId = 1;

  @override
  int get typeId => kTypeId;

  @override
  Dose read(BinaryReader reader) {
    final String title = reader.readString();
    final String notes = reader.readString();
    final int hour = reader.readInt();
    final int minute = reader.readInt();
    final List<int> weekdays = reader.readList().cast<int>();
    final bool isEnabled = reader.readBool();
    return Dose(
      title: title,
      notes: notes,
      hour: hour,
      minute: minute,
      weekdays: weekdays,
      isEnabled: isEnabled,
    );
  }

  @override
  void write(BinaryWriter writer, Dose obj) {
    writer
      ..writeString(obj.title)
      ..writeString(obj.notes)
      ..writeInt(obj.hour)
      ..writeInt(obj.minute)
      ..writeList(obj.weekdays)
      ..writeBool(obj.isEnabled);
  }
}

/*
# Health-Reminder
*/
