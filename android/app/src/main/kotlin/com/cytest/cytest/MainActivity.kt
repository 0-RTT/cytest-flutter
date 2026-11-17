package com.cytest.cytest

import android.annotation.SuppressLint
import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.webkit.CookieManager
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.webkit.ProxyConfig
import androidx.webkit.ProxyController
import androidx.webkit.WebViewFeature
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray

/**
 * 暴露三件事：
 * 1. nativeLibraryDir；
 * 2. 系统文件选择器（SAF），导入 proxyip CSV；
 * 3. **原生 WebView 抓 Censys**（照搬 Kotlin 版 `CensysWebFetcher`）。
 *
 * 为什么抓取要用原生 WebView 而不是插件的 WebView：
 * - 站点是 Fastly 分级放行，纯 HTTP（哪怕带齐浏览器头）会在 TLS 层被拒；
 * - 插件的 `HeadlessInAppWebView` 实现有指纹缺陷（零视口、渲染缺失），过不了挑战；
 * - **原生 `WebView(this)` 不 attach 也能过挑战**（Kotlin 版就是这样，见
 *   `CensysWebFetcher.kt:40`：创建后从不 setContentView / addView）。
 *
 * 关键实现点（全部照抄 Kotlin 版，不要"优化"）：
 * - 轮询而不是等 onPageFinished：每 400ms 读正文开头 4KB，判断是否已返回 JSON；
 * - 正文长度连续 2 轮不变才整段读（避免读到半截）；
 * - 大字符串必须分片读（`evaluateJavascript` 有返回值大小上限），6000 字符一片；
 * - 出现 Fastly clearance cookie（`_fs_ch_st_`）后 reload 一次；
 * - 超时 25s，销毁 WebView。
 */
class MainActivity : FlutterActivity() {
    private val nativeChannelName = "cytest/native"
    private val fileChannelName = "cytest/file"
    private val censysChannelName = "cytest/censys"

    /** 文件选择的回调（同一时刻只允许一个选择器）。 */
    private var pendingPick: MethodChannel.Result? = null

    /** 同一时刻只允许一个 Censys 抓取（WebView 很重，并发没有收益）。 */
    private var censysBusy = false

    private val mainHandler = Handler(Looper.getMainLooper())

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

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, censysChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "fetchSearch" -> {
                        val query = call.argument<String>("query").orEmpty()
                        val proxyPort = call.argument<Int>("proxyPort")
                        val timeoutMs = (call.argument<Int>("timeoutMs") ?: 25000).toLong()
                        startCensysFetch(result, query, proxyPort, timeoutMs)
                    }

                    else -> result.notImplemented()
                }
            }
    }

    // ------------------------------------------------------------------
    // proxyip 文件选择（SAF）
    // ------------------------------------------------------------------

    private fun startPickTextFile(result: MethodChannel.Result) {
        if (pendingPick != null) {
            result.error("busy", "已有一个文件选择器打开，请先完成它", null)
            return
        }
        pendingPick = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            // 只给宽松类型：不同文件管理器上报的 MIME 不一致，限定太死会出现
            // 「文件明明在但选不了」。真正的格式校验在 Dart 侧做。
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
            result.success(String(bytes, Charsets.UTF_8))
        } catch (e: Exception) {
            result.error("read_failed", "读取文件失败：${e.message}", null)
        }
    }

    // ------------------------------------------------------------------
    // 原生 WebView 抓 Censys
    // ------------------------------------------------------------------

    /** 一次抓取的状态（跨多次 Handler 回调）。 */
    private class FetchState(
        val result: MethodChannel.Result,
        val url: String,
        val deadlineMs: Long,
    ) {
        var finished = false
        var webView: WebView? = null
        var proxyMode = "none"
        var sawChallenge = false
        var reloaded = false
        var lastLen = -1
        var stable = 0
        var lastPreview = ""
    }

    private fun startCensysFetch(
        result: MethodChannel.Result,
        query: String,
        proxyPort: Int?,
        timeoutMs: Long,
    ) {
        if (censysBusy) {
            result.error("busy", "上一次抓取还没结束，请稍等", null)
            return
        }
        censysBusy = true
        // WebView 必须在主线程创建
        mainHandler.post {
            val url = "https://platform.censys.io/api/search?q=" + Uri.encode(query)
            val state = FetchState(result, url, System.currentTimeMillis() + timeoutMs)
            try {
                val webView = buildCensysWebView()
                state.webView = webView
                if (proxyPort != null) {
                    applyProxyOverride(state, proxyPort) { ok ->
                        if (!ok) return@applyProxyOverride
                        webView.loadUrl(url)
                        pollCensys(state)
                    }
                    return@post
                }
                webView.loadUrl(url)
                pollCensys(state)
            } catch (e: Throwable) {
                finishCensys(state, error = "创建 WebView 失败：${e.message}")
            }
        }
    }

    @SuppressLint("SetJavaScriptEnabled")
    private fun buildCensysWebView(): WebView {
        // 注意：**不要** attach 到任何 View / setContentView —— Kotlin 版就是
        // 创建后不挂载，照样能过 Fastly 挑战。挂载反而引入尺寸/生命周期问题。
        val webView = WebView(this)
        webView.settings.apply {
            javaScriptEnabled = true
            domStorageEnabled = true
            databaseEnabled = true
            loadsImagesAutomatically = true
            blockNetworkImage = false
            userAgentString = CENSYS_UA
        }
        CookieManager.getInstance().apply {
            setAcceptCookie(true)
            setAcceptThirdPartyCookies(webView, true)
        }
        webView.webViewClient = object : WebViewClient() {}
        return webView
    }

    /**
     * 给 WebView 内核设代理。
     *
     * [onDone] 只回调一次：true = 已生效，false = 失败（此时已把可读错误回给 Dart）。
     * 先试 `http://`，不支持再试 `socks://` —— 与 Kotlin 版一致（默认 scheme 是 http）。
     */
    private fun applyProxyOverride(
        state: FetchState,
        port: Int,
        onDone: (Boolean) -> Unit,
    ) {
        if (!WebViewFeature.isFeatureSupported(WebViewFeature.PROXY_OVERRIDE)) {
            finishCensys(
                state,
                error = "当前系统 WebView 不支持代理覆盖（PROXY_OVERRIDE），无法控制浏览器内核的出口",
            )
            onDone(false)
            return
        }
        val schemes = listOf("http://127.0.0.1:$port", "socks://127.0.0.1:$port")
        var index = 0

        fun attempt() {
            if (state.finished) {
                onDone(false)
                return
            }
            if (index >= schemes.size) {
                finishCensys(state, error = "WebView 代理覆盖没有生效（http/socks 均无回调）")
                onDone(false)
                return
            }
            val rule = schemes[index++]
            val config = ProxyConfig.Builder().addProxyRule(rule).build()
            var called = false
            // 回调要在主线程执行：setProxyOverride 的 executor 决定回调线程
            val mainExecutor = java.util.concurrent.Executor { command -> command.run() }
            ProxyController.getInstance().setProxyOverride(
                config,
                mainExecutor,
            ) {
                if (called) return@setProxyOverride
                called = true
                state.proxyMode = rule
                onDone(true)
            }
            // 6s 没有回调就换下一种 scheme
            mainHandler.postDelayed({
                if (!called) {
                    called = true
                    attempt()
                }
            }, 6000)
        }
        attempt()
    }

    /** 轮询正文，直到拿到完整 JSON / 超时。 */
    private fun pollCensys(state: FetchState) {
        if (state.finished) return
        val webView = state.webView ?: return
        if (System.currentTimeMillis() > state.deadlineMs) {
            finishCensys(state, error = timeoutMessage(state))
            return
        }
        evalJs(webView, SLICE_HEAD_JS) { headRaw ->
            if (state.finished) return@evalJs
            val headText = decodeJsString(headRaw)
            if (headText.isNullOrBlank()) {
                mainHandler.postDelayed({ pollCensys(state) }, POLL_MS)
                return@evalJs
            }
            val head: String = headText
            if (!head.trimStart().startsWith("{")) {
                state.lastPreview = head.take(PREVIEW_CHARS).replace('\n', ' ')
                if (looksChallenged(head)) state.sawChallenge = true
                // 拿到 Fastly clearance cookie 后 reload 一次：挑战通过时页面会自己
                // 重新请求并返回 JSON，但 WebView 不会自动重试当前文档。
                val cookie = CookieManager.getInstance().getCookie(state.url).orEmpty()
                if (cookie.contains(CLEARANCE_COOKIE)) state.sawChallenge = true
                if (!state.reloaded && cookie.contains(CLEARANCE_COOKIE)) {
                    state.reloaded = true
                    state.sawChallenge = false
                    state.stable = 0
                    state.lastLen = -1
                    webView.loadUrl(state.url)
                }
                mainHandler.postDelayed({ pollCensys(state) }, POLL_MS)
                return@evalJs
            }
            // 看起来是 JSON：等长度稳定两轮再整段读，避免读到半截
            evalJs(webView, LENGTH_JS) { lenRaw ->
                if (state.finished) return@evalJs
                val total = decodeJsString(lenRaw)?.trim()?.toIntOrNull() ?: -1
                if (total <= 0) {
                    mainHandler.postDelayed({ pollCensys(state) }, POLL_MS)
                    return@evalJs
                }
                if (total != state.lastLen) {
                    state.lastLen = total
                    state.stable = 0
                    mainHandler.postDelayed({ pollCensys(state) }, POLL_MS)
                    return@evalJs
                }
                state.stable += 1
                if (state.stable < STABLE_ROUNDS) {
                    mainHandler.postDelayed({ pollCensys(state) }, POLL_MS)
                    return@evalJs
                }
                readAll(webView, total, 0, StringBuilder(total)) { body ->
                    if (state.finished) return@readAll
                    if (body != null && body.trimEnd().endsWith("}")) {
                        finishCensys(state, json = body)
                    } else {
                        state.lastLen = -1
                        state.stable = 0
                        mainHandler.postDelayed({ pollCensys(state) }, POLL_MS)
                    }
                }
            }
        }
    }

    /**
     * 分片读回整段正文。
     *
     * 为什么必须分片：`evaluateJavascript` 的返回值会经 Binder 传输，超大字符串会被
     * 截断（实测 > 100KB 就开始丢），而 Censys 响应可能 500KB+。Kotlin 版用 6000
     * 字符一片，这里保持一致。
     */
    private fun readAll(
        webView: WebView,
        total: Int,
        start: Int,
        buffer: StringBuilder,
        onDone: (String?) -> Unit,
    ) {
        if (start >= total) {
            onDone(buffer.toString())
            return
        }
        val end = minOf(start + CHUNK, total)
        val js = SLICE_RANGE_JS.replace("@S", start.toString()).replace("@E", end.toString())
        evalJs(webView, js) { raw ->
            val part = decodeJsString(raw) ?: ""
            if (part.length != end - start) {
                onDone(null) // 读到空白/被截断：调用方下一轮重试
                return@evalJs
            }
            buffer.append(part)
            readAll(webView, total, end, buffer, onDone)
        }
    }

    private fun finishCensys(
        state: FetchState,
        json: String? = null,
        error: String? = null,
    ) {
        if (state.finished) return
        state.finished = true
        censysBusy = false
        val webView = state.webView
        state.webView = null
        if (json != null) {
            state.result.success(json)
        } else {
            state.result.error(
                "fetch_failed",
                error ?: "未知错误",
                mapOf(
                    "proxyMode" to state.proxyMode,
                    "sawChallenge" to state.sawChallenge,
                    "preview" to state.lastPreview,
                ),
            )
        }
        mainHandler.post {
            runCatching { webView?.stopLoading() }
            runCatching { webView?.destroy() }
        }
    }

    private fun timeoutMessage(state: FetchState): String = buildString {
        append("WebView 抓取超时（${TIMEOUT_MS / 1000}s）")
        if (state.sawChallenge) {
            append("，一直停在人机验证页（Fastly 挑战未通过：出口 IP 或 WebView 指纹被拒）")
        }
        if (state.lastPreview.isNotBlank()) append("，最后页面开头：${state.lastPreview}")
    }

    private fun looksChallenged(body: String): Boolean {
        val lower = body.lowercase()
        return CHALLENGE_MARKS.any { lower.contains(it) }
    }

    private fun evalJs(webView: WebView, js: String, onResult: (String?) -> Unit) {
        try {
            webView.evaluateJavascript(js) { raw -> onResult(raw) }
        } catch (e: Throwable) {
            onResult(null)
        }
    }

    /** `evaluateJavascript` 返回的是 JSON 字面量（带引号与转义），这里解回原文。 */
    private fun decodeJsString(raw: String?): String? {
        if (raw == null || raw == "null" || raw.isEmpty()) return null
        return runCatching { JSONArray("[$raw]").getString(0) }.getOrElse { raw }
    }

    companion object {
        private const val REQUEST_PICK_TEXT = 4321

        /** 单文件上限 5MB：proxyip 列表几百 KB 就到头，超大概率是选错了文件。 */
        private const val MAX_BYTES = 5L * 1024 * 1024

        // --- Censys 抓取参数（全部照搬 Kotlin CensysWebFetcher） ---
        private const val POLL_MS = 400L
        private const val STABLE_ROUNDS = 2
        private const val CHUNK = 6000
        private const val PREVIEW_CHARS = 300
        private const val TIMEOUT_MS = 25_000L
        private const val CLEARANCE_COOKIE = "_fs_ch_st_"

        /** 与 Kotlin 版一致的 Android Chrome UA（不是桌面 UA：原生 WebView 用它反而更像真机）。 */
        private const val CENSYS_UA =
            "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 " +
                "(KHTML, like Gecko) Chrome/140.0.0.0 Mobile Safari/537.36"

        /** 先取 `<pre>`（JSON 会被 Chrome 渲染进 pre），没有再退回 body。 */
        private const val TEXT_EXPR =
            "var p=document.querySelector('pre');" +
                "var t=p?p.textContent:(document.body?document.body.textContent:'');"

        private val SLICE_HEAD_JS =
            "(function(){try{$TEXT_EXPR" + "return t.slice(0,4096)}catch(e){return ''}})()"

        private val LENGTH_JS =
            "(function(){try{$TEXT_EXPR" + "return t.length}catch(e){return -1}})()"

        private val SLICE_RANGE_JS =
            "(function(){try{$TEXT_EXPR" + "return t.slice(@S,@E)}catch(e){return ''}})()"

        /** Fastly 挑战页特征（来自项目记忆 e2088dd）。 */
        private val CHALLENGE_MARKS = listOf(
            "/_fs-ch-",
            "fst-post-back",
            "_fs_ch_st",
            "just a moment",
            "checking your browser",
        )
    }
}
