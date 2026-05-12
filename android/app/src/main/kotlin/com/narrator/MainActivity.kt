package com.narrator

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.android.RenderMode
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {

    // FlutterSurfaceView (default) renders into a separate Z-ordered SurfaceView
    // layer that is never composited on Realme/Oppo/MediaTek devices → black screen.
    // FlutterTextureView renders via an OpenGL texture inside the normal View
    // hierarchy, which works correctly on all Android devices.
    override fun getRenderMode(): RenderMode = RenderMode.texture

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        flutterEngine.plugins.add(NarratorPlugin())
    }
}
