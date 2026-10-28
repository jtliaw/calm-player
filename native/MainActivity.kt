package com.calm.calm_player

import android.os.Handler
import android.os.Looper
import com.ryanheise.audioservice.AudioServiceActivity
import com.yausername.ffmpeg.FFmpeg
import com.yausername.youtubedl_android.YoutubeDL
import com.yausername.youtubedl_android.YoutubeDLRequest
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors

class MainActivity : AudioServiceActivity() {
    private val executor = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private val processId = "calm_dl"
    private var ready = false

    @Synchronized
    private fun ensureInit() {
        if (ready) return
        YoutubeDL.getInstance().init(application)
        FFmpeg.getInstance().init(application)
        ready = true
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val ch = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "calm/ytdl")
        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                "download" -> {
                    val url = call.argument<String>("url") ?: ""
                    val dir = call.argument<String>("dir") ?: ""
                    executor.execute {
                        try {
                            ensureInit()
                            File(dir).mkdirs()
                            val req = YoutubeDLRequest(url)
                            req.addOption("-f", "bestaudio[ext=m4a]/bestaudio")
                            req.addOption("-x")
                            req.addOption("--audio-format", "m4a")
                            req.addOption("-i")
                            req.addOption("--no-mtime")
                            req.addOption("--download-archive", "$dir/.archive.txt")
                            req.addOption("-o", "$dir/%(title)s.%(ext)s")
                            YoutubeDL.getInstance().execute(req, processId) { p, _, line ->
                                main.post {
                                    ch.invokeMethod("progress", mapOf("percent" to p.toDouble(), "line" to line))
                                }
                            }
                            main.post { result.success("ok") }
                        } catch (e: Throwable) {
                            main.post { result.error("DL", e.message, e.stackTraceToString()) }
                        }
                    }
                }
                "update" -> {
                    executor.execute {
                        try {
                            ensureInit()
                            val st = YoutubeDL.getInstance().updateYoutubeDL(application)
                            main.post { result.success(st?.toString() ?: "已是最新") }
                        } catch (e: Throwable) {
                            main.post { result.error("UP", e.message, e.stackTraceToString()) }
                        }
                    }
                }
                "cancel" -> {
                    try { YoutubeDL.getInstance().destroyProcessById(processId) } catch (_: Throwable) {}
                    result.success("ok")
                }
                else -> result.notImplemented()
            }
        }
    }
}
