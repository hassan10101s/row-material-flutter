package com.materiallab

import android.app.Activity
import android.os.Bundle
import android.os.CancellationSignal
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.print.PageRange
import android.print.PrintAttributes
import android.print.PrintDocumentAdapter
import android.print.PrintDocumentInfo
import android.print.MaterialLabPdfCallbacks
import android.webkit.WebView
import android.webkit.WebViewClient
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors

/** One off-screen WebView per export; the shipped HTML is the only layout. */
class HtmlPdfRenderer(private val activity: Activity) {
    private val main = Handler(Looper.getMainLooper())
    private val io = Executors.newSingleThreadExecutor()
    private var view: WebView? = null
    private var adapter: PrintDocumentAdapter? = null
    private var descriptor: ParcelFileDescriptor? = null
    private var output: File? = null
    private var pending: MethodChannel.Result? = null
    private var cancellation = CancellationSignal()
    private val timeout = Runnable { fail("HTML to PDF timed out") }

    fun render(html: String, width: Int, height: Int, margins: IntArray, result: MethodChannel.Result) {
        if (pending != null) {
            result.error("PDF_BUSY", "Another report is being rendered", null)
            return
        }
        pending = result
        cancellation = CancellationSignal()
        main.postDelayed(timeout, 60_000)
        try {
            val web = WebView(activity)
            view = web
            web.settings.javaScriptEnabled = true
            web.settings.blockNetworkLoads = true
            web.settings.allowFileAccess = false
            web.settings.allowContentAccess = false
            var started = false
            web.webViewClient = object : WebViewClient() {
                override fun onPageFinished(webView: WebView, url: String) {
                    if (started || pending == null) return
                    started = true
                    awaitAssets(webView) { write(webView, width, height, margins) }
                }
            }
            web.loadDataWithBaseURL(null, html, "text/html", "UTF-8", null)
        } catch (e: Exception) {
            fail(e.message ?: "WebView is unavailable")
        }
    }

    private fun awaitAssets(web: WebView, ready: () -> Unit) {
        if (pending == null) return
        web.evaluateJavascript(
            "document.fonts.status === 'loaded' && Array.from(document.images).every(i => i.complete)"
        ) { value ->
            if (pending != null) {
                if (value == "true") ready()
                else main.postDelayed({ awaitAssets(web, ready) }, 50)
            }
        }
    }

    private fun write(web: WebView, width: Int, height: Int, margins: IntArray) {
        val reply = pending ?: return
        try {
            val file = File.createTempFile("report_", ".pdf", activity.cacheDir)
            output = file
            val fd = ParcelFileDescriptor.open(file,
                ParcelFileDescriptor.MODE_READ_WRITE or ParcelFileDescriptor.MODE_TRUNCATE)
            descriptor = fd
            val print = web.createPrintDocumentAdapter("Material Lab")
            adapter = print
            val attributes = PrintAttributes.Builder()
                .setMediaSize(PrintAttributes.MediaSize("REPORT", "Report", width, height))
                .setResolution(PrintAttributes.Resolution("PDF", "PDF", 300, 300))
                .setMinMargins(PrintAttributes.Margins(margins[0], margins[1], margins[2], margins[3]))
                .setColorMode(PrintAttributes.COLOR_MODE_COLOR).build()
            print.onStart()
            print.onLayout(null, attributes, cancellation,
                object : MaterialLabPdfCallbacks.Layout() {
                    override fun onLayoutFinished(info: PrintDocumentInfo, changed: Boolean) {
                        if (pending !== reply) return
                        print.onWrite(arrayOf(PageRange.ALL_PAGES), fd, cancellation,
                            object : MaterialLabPdfCallbacks.Write() {
                                override fun onWriteFinished(pages: Array<out PageRange>) {
                                    if (pending !== reply) return
                                    io.execute {
                                        try {
                                            val bytes = file.readBytes()
                                            main.post {
                                                if (pending !== reply) return@post
                                                cleanup()
                                                reply.success(bytes)
                                            }
                                        } catch (e: Exception) {
                                            main.post { if (pending === reply) fail(e.message ?: "Cannot read PDF") }
                                        }
                                    }
                                }
                                override fun onWriteFailed(error: CharSequence?) { if (pending === reply) fail(error?.toString() ?: "PDF write failed") }
                                override fun onWriteCancelled() { if (pending === reply) fail("PDF write cancelled") }
                            })
                    }
                    override fun onLayoutFailed(error: CharSequence?) { if (pending === reply) fail(error?.toString() ?: "PDF layout failed") }
                    override fun onLayoutCancelled() { if (pending === reply) fail("PDF layout cancelled") }
                }, Bundle())
        } catch (e: Exception) {
            fail(e.message ?: "Cannot create PDF")
        }
    }

    private fun fail(message: String) {
        val reply = pending
        cleanup()
        reply?.error("HTML_PDF_FAILED", message, null)
    }

    private fun cleanup() {
        pending = null
        main.removeCallbacks(timeout)
        cancellation.cancel()
        try { adapter?.onFinish() } catch (_: Exception) { }
        adapter = null
        try { descriptor?.close() } catch (_: Exception) { }
        descriptor = null
        view?.destroy()
        view = null
        output?.delete()
        output = null
    }

    fun close() {
        fail("Activity closed during PDF export")
        io.shutdown()
    }
}
