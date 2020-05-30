# cython: profile=True

cimport cython

from collections import deque
from threading import local

from .promise cimport Promise
from .schedulers cimport SchedulerFn, Scheduler


cdef class QueueItem:
    pass


@cython.final
cdef class FunctionContainer(QueueItem):
    cdef SchedulerFn fn

    def __init__(self, SchedulerFn fn):
        self.fn = fn


@cython.final
cdef class PromiseContainer(QueueItem):
    cdef public Promise promise

    def __init__(self, Promise promise):
        self.promise = promise


@cython.final
cdef class SettlePromisesFn(SchedulerFn):
    cdef Promise this

    def __init__(self, Promise this):
        self.this = this

    cdef void call(self) except *:
        self.this._settle_promises()


@cython.final
cdef class RaiseFn(SchedulerFn):
    cdef Exception reason

    def __init__(self, Exception reason):
        self.reason = reason

    cdef void call(self) except *:
        raise self.reason


@cython.final
cdef class DrainQueuesFn(SchedulerFn):
    cdef LocalData this

    def __init__(self, LocalData this):
        self.this = this

    cdef void call(self) except *:
        self.this.drain_queues()


@cython.final
cdef class LocalData:
    def __init__(self, bint trampoline_enabled = True):
        self.is_tick_used = False
        self.late_queue = deque()
        self.normal_queue = deque()
        self.have_drained_queues = False
        self.trampoline_enabled = trampoline_enabled

    cdef void enable_trampoline(self):
        self.trampoline_enabled = True

    cdef void disable_trampoline(self):
        self.trampoline_enabled = False

    cdef bint have_items_queued(self):
        return self.is_tick_used or self.have_drained_queues

    cdef void _async_invoke_later(self, SchedulerFn fn, Scheduler scheduler):
        self.late_queue.append(FunctionContainer(fn))
        self.queue_tick(scheduler)

    cdef void _async_invoke(self, SchedulerFn fn, Scheduler scheduler):
        self.normal_queue.append(FunctionContainer(fn))
        self.queue_tick(scheduler)

    cdef void _async_settle_promise(self, Promise promise):
        self.normal_queue.append(PromiseContainer(promise))
        self.queue_tick(promise.get_scheduler())

    cdef void invoke(self, SchedulerFn fn, Scheduler scheduler):
        if self.trampoline_enabled:
            self._async_invoke(fn, scheduler)
        else:
            scheduler.call(fn)

    cdef void settle_promises(self, Promise promise):
        if self.trampoline_enabled:
            self._async_settle_promise(promise)
        else:
            promise.get_scheduler().call(SettlePromisesFn(promise))

    cdef void throw_later(self, Exception reason, Scheduler scheduler):
        scheduler.call(RaiseFn(reason))

    cpdef void fatal_error(self, Exception reason, Scheduler scheduler):
        self.throw_later(reason, scheduler)

    cdef void drain_queue(self, object queue):
        cdef QueueItem fn
        cdef Promise p

        while queue:
            fn = queue.popleft()
            if isinstance(fn, PromiseContainer):
                p = fn.promise
                p._settle_promises()
                continue
            elif isinstance(fn, FunctionContainer):
                fn.fn()

    cdef void drain_queue_until_resolved(self, Promise promise):
        cdef object queue = self.normal_queue
        cdef QueueItem fn
        while queue:
            if not promise.is_pending():
                return
            fn = queue.popleft()
            if isinstance(fn, PromiseContainer):
                fn.promise._settle_promises()
                continue
            elif isinstance(fn, FunctionContainer):
                fn.fn()

        self.reset()
        self.have_drained_queues = True
        self.drain_queue(self.late_queue)

    cdef void wait(self, Promise promise, object timeout = None):
        if not promise.is_pending():
            return

        cdef Promise target = promise._target()

        if self.trampoline_enabled:
            if self.is_tick_used:
                self.drain_queue_until_resolved(target)
            if not promise.is_pending():
                return
        target.get_scheduler().wait(target, timeout)

    cdef void drain_queues(self):
        assert self.is_tick_used
        self.drain_queue(self.normal_queue)
        self.reset()
        self.have_drained_queues = True
        self.drain_queue(self.late_queue)

    cdef void queue_tick(self, Scheduler scheduler):
        if not self.is_tick_used:
            self.is_tick_used = True
            scheduler.call(DrainQueuesFn(self))

    cdef void reset(self):
        self.is_tick_used = False


@cython.final
cdef class Async:
    # FIXME: should have trampoline_enabled attribute and propagate to LocalData
    def __init__(self, bint trampoline_enabled = True):
        self.local = local()
        self.local.data = LocalData(trampoline_enabled)
        self.trampoline_enabled = trampoline_enabled

    cdef LocalData _data(self):
        cdef LocalData data = self.local.data
        if not data:
            data = self.local.data = LocalData(self.trampoline_enabled)
        return data

    cdef void enable_trampoline(self):
        self._data().enable_trampoline()

    cdef void disable_trampoline(self):
        self._data().disable_trampoline()

    cdef bint have_items_queued(self):
        return self._data().have_items_queued()

    cdef void _async_invoke_later(self, SchedulerFn fn, Scheduler scheduler):
        self._data()._async_invoke_later(fn, scheduler)

    cdef void _async_invoke(self, SchedulerFn fn, Scheduler scheduler):
        self._data()._async_invoke(fn, scheduler)

    cdef void _async_settle_promise(self, Promise promise):
        self._data()._async_settle_promise(promise)

    cdef void invoke(self, SchedulerFn fn, Scheduler scheduler):
        self._data().invoke(fn, scheduler)

    cdef public void settle_promises(self, Promise promise):
        self._data().settle_promises(promise)

    cdef void throw_later(self, Exception reason, Scheduler scheduler):
        self._data().throw_later(reason, scheduler)

    cpdef void fatal_error(self, Exception reason, Scheduler scheduler):
        self._data().fatal_error(reason, scheduler)

    cdef void drain_queue(self, object queue):
        self._data().drain_queue(queue)

    cdef void drain_queue_until_resolved(self, Promise promise):
        self._data().drain_queue_until_resolved(promise)

    cdef void wait(self, Promise promise, object timeout = None):
        self._data().wait(promise, timeout)

    cdef void drain_queues(self):
        self._data().drain_queues()

    cdef void queue_tick(self, Scheduler scheduler):
        self._data().queue_tick(scheduler)

    cdef void reset(self):
        self._data().reset()
