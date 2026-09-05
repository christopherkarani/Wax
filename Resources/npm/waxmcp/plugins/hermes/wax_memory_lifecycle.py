"""Session lifecycle coordination for the Hermes Wax memory provider."""

from __future__ import annotations

import json
import logging
import os
import threading
import uuid
from concurrent.futures import Future, ThreadPoolExecutor, wait
from typing import Any, Callable, Dict, List, Optional

logger = logging.getLogger(__name__)


class WaxProviderLifecycle:
    """Owns broker session transitions and background-task admission."""

    def __init__(
        self,
        client: Callable[[], Any],
        reset_transport: Callable[[], None],
    ) -> None:
        self._client = client
        self._reset_transport = reset_transport
        self._session_id: Optional[str] = None
        self._host_session_id = ""
        self._platform = "cli"
        self._cwd = os.getcwd()
        self._project = ""
        self._repo = ""
        self._lifecycle_lock = threading.RLock()
        self._transition_lock = threading.Lock()
        self._initializations_pending = 0
        self._accepting_background = True
        self._shutdown = False
        self._pool: Optional[ThreadPoolExecutor] = None
        self._in_flight: List[Future[None]] = []

    @property
    def session_id(self) -> Optional[str]:
        return self._session_id

    @session_id.setter
    def session_id(self, value: Optional[str]) -> None:
        self._session_id = value

    @property
    def host_session_id(self) -> str:
        return self._host_session_id

    @host_session_id.setter
    def host_session_id(self, value: str) -> None:
        self._host_session_id = value

    @property
    def is_shutdown(self) -> bool:
        with self._lifecycle_lock:
            return self._shutdown

    @property
    def accepting_background(self) -> bool:
        return self._accepting_background

    @accepting_background.setter
    def accepting_background(self, value: bool) -> None:
        self._accepting_background = value

    @property
    def lifecycle_lock(self) -> threading.RLock:
        return self._lifecycle_lock

    @property
    def transition_lock(self) -> threading.Lock:
        return self._transition_lock

    def configure(
        self,
        *,
        platform: Optional[str] = None,
        cwd: Optional[str] = None,
        project: Optional[str] = None,
        repo: Optional[str] = None,
    ) -> None:
        if platform is not None:
            self._platform = platform
        if cwd is not None:
            self._cwd = cwd
        if project is not None:
            self._project = project
        if repo is not None:
            self._repo = repo

    def open_session(self, host_session_id: str) -> None:
        """Map Hermes' opaque conversation ID to a broker-owned Wax UUID."""
        host_session_id = str(host_session_id or "").strip()
        args: Dict[str, Any] = {
            "agent_id": (
                f"hermes-{self._platform}:{host_session_id}"
                if host_session_id
                else f"hermes-{self._platform}"
            ),
            "cwd": self._cwd,
        }
        if host_session_id:
            args["run_id"] = host_session_id
            args["conversation_id"] = host_session_id
        if self._project:
            args["project"] = self._project
        if self._repo:
            args["repo"] = self._repo
        try:
            result = self._client().call_tool("session_open", args)
            if result["ok"]:
                try:
                    payload = json.loads(result["text"]) if result["text"] else {}
                    opened = payload.get("session_id")
                    if opened:
                        uuid.UUID(str(opened))
                    if not opened:
                        raise ValueError("missing session_id")
                    with self._lifecycle_lock:
                        self._session_id = str(opened)
                        self._host_session_id = host_session_id
                    return
                except Exception:
                    logger.error("Wax session_open returned an invalid session_id")
            else:
                logger.error("Wax session_open failed: %s", result.get("text", "unknown"))
        except Exception as exc:
            logger.error("Wax initialize failed: %s", exc)

        # A transport session hint can still reference the prior conversation.
        with self._lifecycle_lock:
            self._session_id = None
            self._host_session_id = host_session_id
        self._reset_transport()

    def initialize_session(
        self,
        host_session_id: str,
        *,
        platform: str,
        cwd: str,
        project: str,
        repo: str,
        prepare: Callable[[], None],
        invalidate_prefetch: Callable[[], int],
    ) -> None:
        with self._lifecycle_lock:
            self._initializations_pending += 1
            self._accepting_background = False
        invalidate_prefetch()
        try:
            with self._transition_lock:
                self.join_background(timeout=None)
                prepare()
                self.configure(
                    platform=platform,
                    cwd=cwd,
                    project=project,
                    repo=repo,
                )
                with self._lifecycle_lock:
                    self._shutdown = False
                self.open_session(host_session_id)
                invalidate_prefetch()
        finally:
            with self._lifecycle_lock:
                self._initializations_pending -= 1
                self._accepting_background = (
                    self._initializations_pending == 0 and not self._shutdown
                )

    def ensure_session(self) -> Optional[str]:
        with self._lifecycle_lock:
            if not self._accepting_background:
                return None
            if self._session_id:
                return self._session_id
            host_session_id = self._host_session_id
        if host_session_id:
            with self._transition_lock:
                with self._lifecycle_lock:
                    if not self._accepting_background:
                        return None
                    if self._session_id:
                        return self._session_id
                self.open_session(host_session_id)
        with self._lifecycle_lock:
            return self._session_id

    def admitted_session(self) -> Optional[str]:
        session_id = self.ensure_session()
        with self._lifecycle_lock:
            return session_id if self.is_admitted(session_id) else None

    def is_admitted(self, session_id: Optional[str]) -> bool:
        return bool(
            session_id
            and self._accepting_background
            and self._session_id == session_id
        )

    def spawn(self, target: Callable[[], None]) -> None:
        with self._lifecycle_lock:
            if not self._accepting_background:
                return
            if self._pool is None:
                self._pool = ThreadPoolExecutor(
                    max_workers=1,
                    thread_name_prefix="wax-mem",
                )
            future = self._pool.submit(target)
            self._in_flight.append(future)
            self._in_flight = [item for item in self._in_flight if not item.done()]

    def join_background(self, timeout: Optional[float] = 2.0) -> bool:
        pending = [item for item in self._in_flight if not item.done()]
        if pending:
            _, unfinished = wait(pending, timeout=timeout)
        else:
            unfinished = set()
        self._in_flight = [item for item in self._in_flight if not item.done()]
        return not unfinished

    def close_pool(self) -> None:
        pool = self._pool
        self._pool = None
        self._in_flight = []
        if pool is not None:
            pool.shutdown(wait=True, cancel_futures=False)

    def switch_session(
        self,
        new_session_id: str,
        *,
        reset: bool,
        rewound: bool,
        cwd: str,
        project: str,
        repo: str,
        invalidate_prefetch: Callable[[], int],
    ) -> bool:
        if rewound and new_session_id == self._host_session_id:
            invalidate_prefetch()
            return False
        with self._transition_lock:
            with self._lifecycle_lock:
                if self._shutdown:
                    return False
                self._accepting_background = False
            try:
                invalidate_prefetch()
                self.join_background(timeout=None)
                self.configure(cwd=cwd, project=project, repo=repo)
                old = self._session_id
                if reset and old:
                    try:
                        result = self._client().call_tool("session_end", {"session_id": old})
                        if not result.get("ok"):
                            logger.error(
                                "Wax session_end during reset failed: %s",
                                result.get("text", "unknown"),
                            )
                    except Exception as exc:
                        logger.debug("Wax session_end during reset failed: %s", exc)
                self.open_session(new_session_id)
                invalidate_prefetch()
            finally:
                with self._lifecycle_lock:
                    self._accepting_background = (
                        self._initializations_pending == 0 and not self._shutdown
                    )
        return True

    def end_session(
        self,
        messages: List[Dict[str, Any]],
        *,
        invalidate_prefetch: Callable[[], int],
    ) -> None:
        with self._transition_lock:
            logger.info("Wax on_session_end triggered")
            with self._lifecycle_lock:
                self._accepting_background = False
                closing_session_id = self._session_id
            invalidate_prefetch()
            self.join_background(timeout=None)
            close_succeeded = closing_session_id is None
            try:
                content = self._handoff_content(closing_session_id, messages)
                if content and closing_session_id:
                    result = self._client().call_tool(
                        "session_close",
                        {
                            "session_id": closing_session_id,
                            "content": content,
                            "pending_tasks": [],
                        },
                    )
                    close_succeeded = bool(result.get("ok"))
                    if not close_succeeded:
                        logger.error(
                            "Wax session_close failed: %s",
                            result.get("text", "unknown"),
                        )
                elif content:
                    logger.warning(
                        "Wax skipped handoff because no active Wax session is available"
                    )
                elif closing_session_id:
                    result = self._client().call_tool(
                        "session_end",
                        {"session_id": closing_session_id},
                    )
                    close_succeeded = bool(result.get("ok"))
                    if not close_succeeded:
                        logger.error(
                            "Wax session_end failed: %s",
                            result.get("text", "unknown"),
                        )
            except Exception as exc:
                logger.error("Wax on_session_end failed: %s", exc)
                close_succeeded = False

            if close_succeeded:
                self._session_id = None
                self._host_session_id = ""
                self._client().close()
                self.close_pool()
            else:
                with self._lifecycle_lock:
                    self._accepting_background = (
                        self._initializations_pending == 0 and not self._shutdown
                    )

    def _handoff_content(
        self,
        closing_session_id: Optional[str],
        messages: List[Dict[str, Any]],
    ) -> str:
        content = ""
        if closing_session_id:
            try:
                result = self._client().call_tool(
                    "session_synthesize",
                    {"session_id": closing_session_id},
                )
                if result["ok"] and result["text"]:
                    try:
                        payload = json.loads(result["text"])
                        content = (
                            payload.get("handoff")
                            or payload.get("content")
                            or payload.get("summary")
                            or result["text"]
                        )
                    except Exception:
                        content = result["text"]
            except Exception as exc:
                logger.debug("Wax session_synthesize failed: %s", exc)
        if not content:
            parts = []
            for message in messages[-6:]:
                role = message.get("role", "")
                text = message.get("content", "")
                if text and len(str(text)) < 500:
                    parts.append(f"{role}: {str(text)[:200]}")
            content = "\n".join(parts)
        return content

    def shutdown(
        self,
        manager_shutdown: Callable[[], None],
        *,
        invalidate_prefetch: Callable[[], int],
    ) -> None:
        with self._transition_lock:
            with self._lifecycle_lock:
                self._shutdown = True
                self._accepting_background = False
            invalidate_prefetch()
            self.join_background(timeout=None)
            if self._session_id:
                try:
                    result = self._client().call_tool(
                        "session_end",
                        {"session_id": self._session_id},
                    )
                    if not result.get("ok"):
                        logger.error(
                            "Wax shutdown session_end failed: %s",
                            result.get("text", "unknown"),
                        )
                except Exception as exc:
                    logger.debug("Wax shutdown cleanup failed: %s", exc)
                finally:
                    self._session_id = None
                    self._host_session_id = ""
            self._client().close()
            manager_shutdown()
            self.close_pool()
            invalidate_prefetch()
