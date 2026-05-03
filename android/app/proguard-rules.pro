# Flutter wrap
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.**  { *; }
-keep class io.flutter.util.**  { *; }
-keep class io.flutter.view.**  { *; }
-keep class io.flutter.**  { *; }
-keep class io.flutter.plugins.**  { *; }
-keep class com.arthenica.** { *; }
-keep class com.antonkarpenko.** { *; }
-keep class com.ryanheise.** { *; }

# Application classes
-keep class com.example.music_player.** { *; }

# Media3 (reflection-based initialization for MediaSession)
-keep class androidx.media3.** { *; }

# Kotlin metadata
-keepattributes *Annotation*, InnerClasses, Signature, EnclosingMethod

-keepclassmembers class * extends java.lang.Enum {
    <fields>;
    public static **[] values();
    public static ** valueOf(java.lang.String);
}

# Ignore missing Play Core classes for Flutter deferred components
-dontwarn com.google.android.play.core.**
-dontwarn io.flutter.embedding.engine.deferredcomponents.PlayStoreDeferredComponentManager
