# Room: keep generated *_Impl classes and their no-arg constructors.
# The Room AAR ships "-keep class * extends RoomDatabase" but that only
# protects the class from removal/renaming — R8 still strips the no-arg
# constructor because it's only ever called via Class.getDeclaredConstructors()
# (reflection inside RoomDatabase.create()), which R8 cannot trace statically.
-keep class * extends androidx.room.RoomDatabase { <init>(); }
-dontwarn androidx.room.paging.**
-dontwarn androidx.lifecycle.LiveData

# WorkManager: keep worker classes, their two-arg constructors, and the
# WorkerParameters type passed to them.  Sourced from work-runtime AAR's
# own proguard.txt — re-stated here so they apply even if transitive
# consumer-rule propagation through the Flutter plugin wrapper is incomplete.
-keepnames class * extends androidx.work.ListenableWorker
-keepclassmembers public class * extends androidx.work.ListenableWorker {
    public <init>(...);
}
-keep class androidx.work.WorkerParameters
-keepnames class * extends androidx.work.InputMerger
-keepclassmembers class * extends androidx.work.InputMerger { void <init>(); }
