/*
 * Copyright 2022, the Chromium project authors.  Please see the AUTHORS file
 * for details. All rights reserved. Use of this source code is governed by a
 * BSD-style license that can be found in the LICENSE file.
 */
package io.flutter.plugins.firebase.auth

import android.os.Handler
import android.os.Looper
import com.google.firebase.auth.FirebaseAuth
import io.flutter.plugin.common.EventChannel.EventSink
import io.flutter.plugin.common.EventChannel.StreamHandler
import java.util.concurrent.atomic.AtomicBoolean

class IdTokenChannelStreamHandler(private val firebaseAuth: FirebaseAuth) : StreamHandler {
  private val mainThreadHandler = Handler(Looper.getMainLooper())
  private val isListening = AtomicBoolean(false)
  private var idTokenListener: FirebaseAuth.IdTokenListener? = null

  override fun onListen(arguments: Any?, events: EventSink) {
    isListening.set(true)

    val initialAuthState = AtomicBoolean(true)

    idTokenListener =
        FirebaseAuth.IdTokenListener { auth: FirebaseAuth ->
          if (initialAuthState.get()) {
            initialAuthState.set(false)
            return@IdTokenListener
          }

          val event: MutableMap<String, Any?> = HashMap()
          event[Constants.APP_NAME] = auth.app.name

          val user = auth.currentUser
          if (user == null) {
            event[Constants.USER] = null
          } else {
            event[Constants.USER] =
                PigeonParser.manuallyToList(PigeonParser.parseFirebaseUser(user)!!)
          }

          val sendEvent = Runnable {
            if (isListening.get()) {
              events.success(event)
            }
          }
          if (Looper.myLooper() == Looper.getMainLooper()) {
            sendEvent.run()
          } else {
            mainThreadHandler.post(sendEvent)
          }
        }

    firebaseAuth.addIdTokenListener(idTokenListener!!)
  }

  override fun onCancel(arguments: Any?) {
    isListening.set(false)
    if (idTokenListener != null) {
      firebaseAuth.removeIdTokenListener(idTokenListener!!)
      idTokenListener = null
    }
  }
}
