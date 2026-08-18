package com.example.excerpt

import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import java.io.File

/**
 * Native Android helper for the SAME database used by Flutter/sqflite:
 *
 *     filesDir/excerpt.db
 *
 * IMPORTANT:
 * Keep this schema in sync with AppDatabase._createV1() in data.dart.
 */
class ExcerptDatabaseHelper(context: Context) :
    SQLiteOpenHelper(
        context.applicationContext,
        File(context.applicationContext.filesDir, DATABASE_NAME).absolutePath,
        null,
        DATABASE_VERSION
    ) {

    companion object {
        private const val DATABASE_NAME = "excerpt.db"
        private const val DATABASE_VERSION = 1
    }

    override fun onConfigure(db: SQLiteDatabase) {
        super.onConfigure(db)

        // Same as Flutter:
        // PRAGMA foreign_keys = ON
        db.setForeignKeyConstraintsEnabled(true)

        // Helps Flutter/sqflite and this native service
        // work with the same SQLite file concurrently.
        try {
            db.enableWriteAheadLogging()
        } catch (_: Exception) {
            // WAL is an optimization, not a requirement.
        }
    }

    override fun onCreate(db: SQLiteDatabase) {

        db.execSQL(
            """
            CREATE TABLE folders (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                name TEXT NOT NULL UNIQUE,
                created_at TEXT NOT NULL
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
                type TEXT NOT NULL DEFAULT 'system',
                timestamp TEXT NOT NULL,
                important INTEGER NOT NULL DEFAULT 0,
                edited INTEGER NOT NULL DEFAULT 0,
                extra TEXT,
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
        // Keep this in sync with data.dart migrations.
        //
        // Example for schema version 2:
        //
        // if (oldVersion < 2) {
        //     db.execSQL(
        //         "ALTER TABLE messages ADD COLUMN pinned INTEGER NOT NULL DEFAULT 0"
        //     )
        // }
    }
}