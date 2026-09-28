package com.kuhy.diet_guard_app

import io.flutter.embedding.android.FlutterFragmentActivity

// FlutterFragmentActivity, not FlutterActivity: the `health` plugin requests
// Health Connect permissions through registerForActivityResult, which needs a
// ComponentActivity (see the plugin README, "Android 14").
class MainActivity : FlutterFragmentActivity()
