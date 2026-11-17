package com.cytest.cytest

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * 只暴露一件事：nativeLibraryDir。
 *
 * 打包进 jniLibs 的 libpipeline.so / libxray.so 会被系统解压到该目录并赋予可执行权限；
 * 直接在 filesDir 里 chmod 会被 SELinux 拦掉（ProcessException: Permission denied）。
 */
class MainActivity : FlutterActivity() {
    private val channelName = "cytest/native"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "nativeLibraryDir" -> result.success(applicationInfo.nativeLibraryDir)
                    else -> result.notImplemented()
                }
            }
    }
}
