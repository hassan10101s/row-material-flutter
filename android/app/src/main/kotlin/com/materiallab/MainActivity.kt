package com.materiallab

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    companion object {
        private const val CHANNEL = "material_lab/qr_camera"
        private const val REQUEST_CAMERA = 1001
    }

    private var pendingResult: MethodChannel.Result? = null
    private var htmlPdf: HtmlPdfRenderer? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val renderer = HtmlPdfRenderer(this)
        htmlPdf = renderer
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "material_lab/html_pdf")
            .setMethodCallHandler { call, result ->
                val html = call.argument<String>("html")
                if (call.method != "render") result.notImplemented()
                else if (html == null) result.error("INVALID_HTML", "HTML is required", null)
                else renderer.render(html,
                    call.argument<Int>("widthMils") ?: 8268,
                    call.argument<Int>("heightMils") ?: 11693,
                    intArrayOf(call.argument<Int>("leftMils") ?: 0,
                        call.argument<Int>("topMils") ?: 0,
                        call.argument<Int>("rightMils") ?: 0,
                        call.argument<Int>("bottomMils") ?: 0), result)
            }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                // No-op when already granted (no system dialog); otherwise
                // shows the one-time system dialog. Called only from the QR
                // scanner, never at app start.
                "request" -> {
                    if (checkStatus() == "granted") {
                        result.success(true)
                    } else {
                        // A second overlapping request would leak the first
                        // callback; drop it rather than answering twice.
                        pendingResult?.let {
                            try {
                                it.success(false)
                            } catch (_: Exception) {
                            }
                        }
                        pendingResult = result
                        requestPermissions(
                            arrayOf(Manifest.permission.CAMERA),
                            REQUEST_CAMERA,
                        )
                    }
                }
                "check" -> result.success(checkStatus())
                "openSettings" -> {
                    startActivity(
                        Intent(
                            Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                            Uri.fromParts("package", packageName, null),
                        ),
                    )
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onDestroy() {
        htmlPdf?.close()
        htmlPdf = null
        super.onDestroy()
    }

    private fun checkStatus(): String {
        if (checkSelfPermission(Manifest.permission.CAMERA) ==
            PackageManager.PERMISSION_GRANTED
        ) {
            return "granted"
        }
        // Before the first request the rationale is always false, so this
        // reports "permanentlyDenied" until the user has denied once. The
        // Dart side always calls "request" first, which is exact, and uses
        // "check" only to pick the right button afterwards.
        return if (shouldShowRequestPermissionRationale(Manifest.permission.CAMERA)) {
            "denied"
        } else {
            "permanentlyDenied"
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == REQUEST_CAMERA) {
            pendingResult?.success(
                grantResults.isNotEmpty() &&
                    grantResults[0] == PackageManager.PERMISSION_GRANTED,
            )
            pendingResult = null
        }
    }
}
