package com.clipshare.android.data

import android.content.Context
import androidx.room.*

@Entity(tableName = "outbox")
data class OutboxItem(
    @PrimaryKey val id: String,
    val seq: Int,
    val envelopeJson: String,
    val timestamp: Long,
    val delivered: Boolean
)

@Dao
interface OutboxDao {
    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insert(item: OutboxItem)

    @Query("SELECT * FROM outbox WHERE delivered = 0 ORDER BY seq ASC")
    suspend fun getPendingItems(): List<OutboxItem>

    @Query("UPDATE outbox SET delivered = 1 WHERE id = :id")
    suspend fun markDelivered(id: String)

    @Query("DELETE FROM outbox WHERE delivered = 1 AND timestamp < :cutoff")
    suspend fun deleteOldDelivered(cutoff: Long)

    @Query("SELECT COUNT(*) FROM outbox WHERE delivered = 0")
    suspend fun getPendingCount(): Int
}

@Database(entities = [OutboxItem::class], version = 1, exportSchema = false)
abstract class AppDatabase : RoomDatabase() {
    abstract fun outboxDao(): OutboxDao

    companion object {
        @Volatile
        private var INSTANCE: AppDatabase? = null

        fun getInstance(context: Context): AppDatabase {
            return INSTANCE ?: synchronized(this) {
                val instance = Room.databaseBuilder(
                    context.applicationContext,
                    AppDatabase::class.java,
                    "clipboard_sync_db"
                )
                    .setJournalMode(JournalMode.WRITE_AHEAD_LOGGING) // WAL mode for better concurrency
                    .build()

                INSTANCE = instance
                instance
            }
        }
    }
}
