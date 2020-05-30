# Based on https://github.com/petkaantonov/bluebird/blob/master/src/promise.js
from collections import deque
from threading import local

if False:
    from .promise import Promise
    from typing import Callable, Optional  # flake8: noqa


class Async(local):
    __slots__ = (
        "is_tick_used",
        "late_queue",
        "normal_queue",
        "have_drained_queues",
        "trampoline_enabled",
    )

    is_tick_used: bool
    late_queue: deque
    normal_queue: deque
    have_drained_queues: bool
    trampoline_enabled: bool

    def __init__(self, trampoline_enabled: bool = True):
        self.is_tick_used = False
        self.late_queue = deque()
        self.normal_queue = deque()
        self.have_drained_queues = False
        self.trampoline_enabled = trampoline_enabled

    def enable_trampoline(self):
        self.trampoline_enabled = True

    def disable_trampoline(self):
        self.trampoline_enabled = False

    def have_items_queued(self) -> bool:
        return self.is_tick_used or self.have_drained_queues

    def _async_invoke_later(self, fn: "Callable", scheduler):
        self.late_queue.append(fn)
        self.queue_tick(scheduler)

    def _async_invoke(self, fn: "Callable", scheduler):
        self.normal_queue.append(fn)
        self.queue_tick(scheduler)

    def _async_settle_promise(self, promise: "Promise"):
        self.normal_queue.append(promise)
        self.queue_tick(promise.get_scheduler())

    def invoke(self, fn: "Callable", scheduler):
        if self.trampoline_enabled:
            self._async_invoke(fn, scheduler)
        else:
            scheduler.call(fn)

    def settle_promises(self, promise: "Promise"):
        if self.trampoline_enabled:
            self._async_settle_promise(promise)
        else:
            promise.get_scheduler().call(promise._settle_promises)

    def throw_later(self, reason: Exception, scheduler):
        def fn():
            raise reason

        scheduler.call(fn)

    fatal_error = throw_later

    def drain_queue(self, queue: deque):
        from .promise import Promise

        while queue:
            fn = queue.popleft()
            if isinstance(fn, Promise):
                fn._settle_promises()
                continue
            fn()

    def drain_queue_until_resolved(self, promise: "Promise"):
        from .promise import Promise

        queue = self.normal_queue
        while queue:
            if not promise.is_pending():
                return
            fn = queue.popleft()
            if isinstance(fn, Promise):
                fn._settle_promises()
                continue
            fn()

        self.reset()
        self.have_drained_queues = True
        self.drain_queue(self.late_queue)

    def wait(self, promise: "Promise", timeout: "Optional[float]" = None):
        if not promise.is_pending():
            # We return if the promise is already
            # fulfilled or rejected
            return

        target = promise._target()

        if self.trampoline_enabled:
            if self.is_tick_used:
                self.drain_queue_until_resolved(target)

            if not promise.is_pending:
                # We return if the promise is already
                # fulfilled or rejected
                return
        target.scheduler.wait(target, timeout)

    def drain_queues(self):
        assert self.is_tick_used
        self.drain_queue(self.normal_queue)
        self.reset()
        self.have_drained_queues = True
        self.drain_queue(self.late_queue)

    def queue_tick(self, scheduler):
        if not self.is_tick_used:
            self.is_tick_used = True
            scheduler.call(self.drain_queues)

    def reset(self):
        self.is_tick_used = False
