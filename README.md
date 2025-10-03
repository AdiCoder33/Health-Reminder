# Health Reminder

A Flutter application for managing health reminders and notifications.

## Android contributor notes

### Gradle wrapper JAR

The Gradle wrapper JAR (`android/gradle/wrapper/gradle-wrapper.jar`) is intentionally not tracked in git.
If you need the wrapper locally, regenerate it with:

```bash
cd android
./gradlew wrapper --gradle-version <version-you-need>
```

or, if the wrapper scripts are also missing, run:

```bash
gradle wrapper --gradle-version <version-you-need>
```

This command recreates the wrapper JAR without committing the binary to the repository.

### Launcher icons

Android launcher icons are defined via XML/vector resources in `android/app/src/main/res` so
no binary PNGs need to be stored in git. If you update the icon, modify the vector drawables
instead of adding bitmap assets.

### Tablet reminder sound

The repository does not ship the `tablet_time.wav` notification sound. To test or ship a
custom sound, place your WAV file at `android/app/src/main/res/raw/tablet_time.wav` locally
(or configure a different filename in the Android manifest metadata). The build will succeed
without this optional file.
