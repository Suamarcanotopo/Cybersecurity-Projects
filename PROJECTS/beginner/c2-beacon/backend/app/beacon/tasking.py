"""
AngelaMos | 2026
tasking.py

Per-beacon asyncio task queues backed by SQLite persistence

TaskManager maintains an asyncio.Queue per beacon for pending tasks.
submit writes to SQLite and enqueues; get_next blocks until a task is
available; store_result persists the result and marks the task
completed; get_history returns tasks joined with their results.

Connects to:
  core/models.py - uses TaskRecord, TaskResult
  beacon/router.py - calls get_next, store_result, remove_queue
  ops/router.py - calls submit, get_history
  __main__.py - creates singleton on startup
  tests/test_tasking.py - tests all task lifecycle methods
"""

import asyncio

import aiosqlite

from app.core.models import TaskRecord, TaskResult


class TaskManager:
    """
    Per-beacon async task queues backed by SQLite persistence
    """
    def __init__(self) -> None:
        """
        Initialize empty queue registry
        """
        self._queues: dict[str, asyncio.Queue[TaskRecord]] = {}

    def _ensure_queue(self, beacon_id: str) -> asyncio.Queue[TaskRecord]:
        """
        Create a task queue for a beacon if one does not exist
        """
        if beacon_id not in self._queues:
            self._queues[beacon_id] = asyncio.Queue()
        return self._queues[beacon_id]

    async def submit(
        self,
        task: TaskRecord,
        db: aiosqlite.Connection,
    ) -> None:
        """
        Persist a task to SQLite and enqueue it for beacon delivery
        """
        await db.execute(
            """
            INSERT INTO tasks (id, beacon_id, command, args, status, created_at)
            VALUES (?, ?, ?, ?, ?, ?)
            """,
            (
                task.id,
                task.beacon_id,
                task.command,
                task.args,
                task.status,
                task.created_at,
            ),
        )
        await db.commit()

        queue = self._ensure_queue(task.beacon_id)
        await queue.put(task)

    async def get_next(self, beacon_id: str) -> TaskRecord:
        """
        Await the next task for a beacon (blocks until available)
        """
        queue = self._ensure_queue(beacon_id)
        return await queue.get()

    async def store_result(
        self,
        result: TaskResult,
        db: aiosqlite.Connection,
    ) -> None:
        """
        Persist a task result and mark the parent task as completed
        """
        await db.execute(
            """
            INSERT INTO task_results (id, task_id, output, error, created_at)
            VALUES (?, ?, ?, ?, ?)
            """,
            (
                result.id,
                result.task_id,
                result.output,
                result.error,
                result.created_at,
            ),
        )
        await db.execute(
            "UPDATE tasks SET status = 'completed', completed_at = ? WHERE id = ?",
            (result.created_at,
             result.task_id),
        )
        await db.commit()

    async def get_history(
        self,
        beacon_id: str,
        db: aiosqlite.Connection,
    ) -> list[dict[str,
                   str | None]]:
        """
        Retrieve task history with results for a specific beacon
        """
        cursor = await db.execute(
            """
            SELECT
                t.id, t.command, t.args, t.status, t.created_at, t.completed_at,
                tr.output, tr.error
            FROM tasks t
            LEFT JOIN task_results tr ON t.id = tr.task_id
            WHERE t.beacon_id = ?
            ORDER BY t.created_at DESC
            """,
            (beacon_id,
             ),
        )
        rows = await cursor.fetchall()
        return [dict(row) for row in rows]

    def remove_queue(self, beacon_id: str) -> None:
        """
        Clean up the task queue when a beacon disconnects
        """
        self._queues.pop(beacon_id, None)
