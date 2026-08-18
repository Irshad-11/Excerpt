package com.example.excerpt

object Prefs {

    const val NAME = "excerpt_prefs"

    const val KEY_ENABLED =
        "clipboard_enabled"

    const val KEY_LAST_CLIPBOARD =
        "last_clipboard"

    const val KEY_PENDING_TEXT =
        "pending_clip_text"

    // Remembers the folder the user picked last time,
    // so it can be pinned at the top of the overlay's
    // folder list next time.
    const val KEY_LAST_FOLDER =
        "last_used_folder"

    const val ACTION_SAVE_CLIP =
        "com.example.excerpt.ACTION_SAVE_CLIP"

    const val ACTION_CHANGE_KEYBOARD =
        "com.example.excerpt.ACTION_CHANGE_KEYBOARD"
}