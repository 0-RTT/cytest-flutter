package com.cytest.cytest

import android.app.Activity
import android.content.Intent
import android.net.Uri
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * 暴露两件事：
 * 1. nativeLibraryDir（见下）；
 * 2. 系统文件选择器（SAF `ACTION_OPEN_DOCUMENT`），用于导入 proxyip CSV。
 *
 * 为什么不加第三方依赖（file_picker 等）：AGP 9 兼容性未知，而 SAF 用系统 API
 * 就够 —— 一个 Intent + onActivityResult，零依赖。
 *
 * 为什么用经典 `startActivityForResult` 而不是 `registerForActivityResult`：
 * 后者要求宿主是 `androidx.activity.ComponentActivity`，而 FlutterActivity 的基类
 * 在不同 Flutter 版本间变过；经典 API 在所有版本都能用，代价只是一个
 * deprecated 注解（功能完全正常）。
 */
class MainActivity : FlutterActivity() {
    private val nativeChannelName = "cytest/native"
    private val fileChannelName = "cytest/file"

    /** 文件选择的回调（同一时刻只允许一个选择器）。 */
    private var pendingPick: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // 打包进 jniLibs 的 libpipeline.so / libxray.so 会被系统解压到该目录并赋予
        // 可执行权限；直接在 filesDir 里 chmod 会被 SELinux 拦掉。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, nativeChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "nativeLibraryDir" -> result.success(applicationInfo.nativeLibraryDir)
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, fileChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "pickTextFile" -> startPickTextFile(result)
                    else -> result.notImplemented()
                }
            }
    }

    private fun startPickTextFile(result: MethodChannel.Result) {
        if (pendingPick != null) {
            result.error("busy", "已有一个文件选择器打开，请先完成它", null)
            return
        }
        pendingPick = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            // 只给宽松类型：不同文件管理器上报的 MIME 不一致，限定太死会出现
            // 「文件明明在但选不了」。真正的格式校验在 Dart 侧做（失败给可读原因）。
            type = "*/*"
            putExtra(
                Intent.EXTRA_MIME_TYPES,
                arrayOf(
                    "text/*",
                    "text/csv",
                    "text/comma-separated-values",
                    "application/csv",
                    "application/octet-stream",
                ),
            )
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        try {
            @Suppress("DEPRECATION")
            startActivityForResult(intent, REQUEST_PICK_TEXT)
        } catch (e: Exception) {
            pendingPick = null
            result.error("no_picker", "无法打开系统文件选择器：${e.message}", null)
        }
    }

    @Deprecated("FlutterActivity 基类在不同 Flutter 版本间变化，经典 API 更稳")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode != REQUEST_PICK_TEXT) {
            super.onActivityResult(requestCode, resultCode, data)
            return
        }
        val result = pendingPick
        pendingPick = null
        if (result == null) return

        val uri: Uri? = if (resultCode == Activity.RESULT_OK) data?.data else null
        if (uri == null) {
            result.success(null) // 用户取消：返回 null，不抛异常
            return
        }
        try {
            val known = contentResolver.openAssetFileDescriptor(uri, "r")?.use { it.length } ?: -1L
            if (known > MAX_BYTES) {
                result.error("too_large", "文件过大：$known 字节（上限 $MAX_BYTES）", null)
                return
            }
            val bytes = contentResolver.openInputStream(uri)?.use { it.readBytes() }
                ?: throw IllegalStateException("无法打开所选文件（openInputStream 返回 null）")
            if (bytes.size > MAX_BYTES) {
                result.error("too_large", "文件过大：${bytes.size} 字节（上限 $MAX_BYTES）", null)
                return
            }
            // proxyip CSV 一定是 UTF-8 文本；非法字节会被替换字符代替，
            // 随后在 Dart 侧解析时按非法行跳过，不会污染列表。
            result.success(String(bytes, Charsets.UTF_8))
        } catch (e: Exception) {
            result.error("read_failed", "读取文件失败：${e.message}", null)
        }
    }

    companion object {
        private const val REQUEST_PICK_TEXT = 4321

        /** 单文件上限 5MB：proxyip 列表几百 KB 就到头，超大概率是选错了文件。 */
        private const val MAX_BYTES = 5L * 1024 * 1024
    }
}
