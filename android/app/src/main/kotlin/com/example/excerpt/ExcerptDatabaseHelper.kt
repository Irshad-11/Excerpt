package com.example.excerpt

import android.content.ContentValues
import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import android.util.Log
import java.io.File

/**
 * Native Android helper for the SAME database used by Flutter/sqflite:
 *
 *     filesDir/excerpt.db
 *
 * IMPORTANT:
 * Keep DATABASE_VERSION and onUpgrade() in sync with
 * AppDatabase.schemaVersion / onUpgrade in data.dart — Flutter and
 * this native service open the exact same physical SQLite file, and
 * Android's SQLiteOpenHelper stores the schema version *inside that
 * file* (PRAGMA user_version). If one side's version number is behind
 * the other, SQLiteOpenHelper treats it as a "downgrade" and throws
 * on open by default, which silently breaks the native side (folders
 * appear to vanish) while Flutter keeps working fine.
 *
 * Whenever data.dart's schemaVersion changes, mirror it here:
 *   1. Bump DATABASE_VERSION by the same amount.
 *   2. Add a matching `if (oldVersion < N) { ... }` block below.
 *
 * v3: the old `type` column meant two different things at once
 * ('system'/'user'/'image'). It's now split into:
 *   type   — WHAT the message is:  'text' | 'image'
 *   source — WHO sent it:          'user' | 'system'
 * The overlay (ExcerptInputMethodService) writes source='system' for
 * every message it saves, since it only ever captures clipboard text.
 */
class ExcerptDatabaseHelper(context: Context) :
    SQLiteOpenHelper(
        context.applicationContext,
        File(context.applicationContext.filesDir, DATABASE_NAME).absolutePath,
        null,
        DATABASE_VERSION
    ) {

    companion object {
        private const val TAG = "ExcerptDB"
        private const val DATABASE_NAME = "excerpt.db"

        // Must match AppDatabase.schemaVersion in data.dart.
        private const val DATABASE_VERSION = 3
    }

    override fun onConfigure(db: SQLiteDatabase) {
        super.onConfigure(db)

        db.setForeignKeyConstraintsEnabled(true)

        try {
            db.enableWriteAheadLogging()
        } catch (_: Exception) {
            // WAL is an optimization, not a requirement.
        }
    }

    override fun onCreate(db: SQLiteDatabase) {
        // Fresh install: create the CURRENT (v3) schema directly.

        db.execSQL(
            """
            CREATE TABLE folders (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                name TEXT NOT NULL UNIQUE,
                created_at TEXT NOT NULL,
                archived INTEGER NOT NULL DEFAULT 0
            )
            """.trimIndent()
        )

        db.execSQL(
            """
            CREATE TABLE messages (
                seq INTEGER PRIMARY KEY AUTOINCREMENT,
                id TEXT NOT NULL UNIQUE,
                folder_id INTEGER NOT NULL,
                text TEXT NOT NULL,
                type TEXT NOT NULL DEFAULT 'text',
                source TEXT NOT NULL DEFAULT 'user',
                timestamp TEXT NOT NULL,
                important INTEGER NOT NULL DEFAULT 0,
                edited INTEGER NOT NULL DEFAULT 0,
                extra TEXT,
                image_path TEXT,
                FOREIGN KEY (folder_id) REFERENCES folders (id) ON DELETE CASCADE
            )
            """.trimIndent()
        )

        db.execSQL(
            "CREATE INDEX idx_messages_folder ON messages (folder_id)"
        )

        db.execSQL(
            "CREATE INDEX idx_messages_timestamp ON messages (timestamp)"
        )

        db.execSQL(
            """
            CREATE TABLE app_meta (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
            )
            """.trimIndent()
        )
    }

    override fun onUpgrade(
        db: SQLiteDatabase,
        oldVersion: Int,
        newVersion: Int
    ) {
        Log.i(TAG, "Upgrading Excerpt DB from $oldVersion to $newVersion")

        if (oldVersion < 2) {
            addColumnIfMissing(db, "folders", "archived", "INTEGER NOT NULL DEFAULT 0")
            addColumnIfMissing(db, "messages", "image_path", "TEXT")
        }

        if (oldVersion < 3) {
            val added = addColumnIfMissing(
                db, "messages", "source", "TEXT NOT NULL DEFAULT 'user'"
            )

            if (added) {
                // Backfill from the old overloaded `type` column, same
                // logic as AppDatabase._upgradeToV3 in data.dart.
                db.execSQL("UPDATE messages SET source = 'system' WHERE type = 'system'")
                db.execSQL("UPDATE messages SET type = 'text' WHERE type IN ('system', 'user')")
            }
        }

        // Next migration goes here, e.g.:
        // if (oldVersion < 4) { ... }
    }

    /**
     * Defensive only. This should not normally run — it exists so that
     * if a schema-version mismatch ever happens again (native ahead of
     * Flutter, or vice versa), opening the database degrades safely
     * instead of throwing and silently breaking folder/message reads.
     */
    override fun onDowngrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) {
        Log.w(
            TAG,
            "DB reports version $oldVersion but this helper requests $newVersion — " +
                "leaving schema as-is instead of throwing. Update DATABASE_VERSION " +
                "in ExcerptDatabaseHelper to match AppDatabase.schemaVersion in data.dart."
        )
        // Intentionally do nothing destructive. SQLite schemas here are
        // additive-only, so an "older" requested version can still read
        // a newer on-disk schema without any changes.
    }

    private fun addColumnIfMissing(
        db: SQLiteDatabase,
        table: String,
        column: String,
        definition: String
    ): Boolean {
        val hasColumn = db.rawQuery("PRAGMA table_info($table)", null).use { cursor ->
            val nameIndex = cursor.getColumnIndex("name")
            var found = false
            while (cursor.moveToNext()) {
                if (nameIndex >= 0 && cursor.getString(nameIndex) == column) {
                    found = true
                    break
                }
            }
            found
        }

        if (!hasColumn) {
            db.execSQL("ALTER TABLE $table ADD COLUMN $column $definition")
            return true
        }
        return false
    }
}