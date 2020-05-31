cimport cython

from threading import local
from cpython.exc cimport PyErr_SetString

from .promise cimport Promise
from .schedulers cimport SchedulerFn, Scheduler


cdef class QueueItem:
    pass


@cython.final
cdef class Queue:
    cdef inline bint is_empty(self):
        return self.length == 0

    cdef void push(self, QueueItem item):
        self.length += 1
        self.items.append(item)

    cdef QueueItem shift(self):
        if self.is_empty():
            return None
        cdef:
            QueueItem item = self.items[self.offset]
        self.items[self.offset] = None
        self.length -= 1
        self.offset += 1
        if self.length > 8 and self.offset >= self.length:
            self.items = self.items[self.offset:]
            self.offset = 0
        return item


cdef Queue make_queue():
    cdef Queue q = Queue()
    q.length = q.offset = 0
    q.items = []
    return q


@cython.final
cdef class FunctionContainer(QueueItem):
    cdef SchedulerFn fn


@cython.final
cdef class PromiseContainer(QueueItem):
    cdef Promise promise


@cython.final
cdef class SettlePromisesFn(SchedulerFn):
    cdef Promise promise

    cdef void call(self) except *:
        self.promise._settle_promises()


@cython.final
cdef class RaiseFn(SchedulerFn):
    cdef Exception reason

    cdef void call(self) except *:
        raise self.reason


@cython.final
cdef class DrainQueuesFn(SchedulerFn):
    cdef LocalData localdata

    cdef void call(self) except *:
        self.localdata.drain_queues()


@cython.final
cdef class LocalData:
    def __init__(self, bint trampoline_enabled = True):
        self.is_tick_used = False
        self.late_queue = make_queue()
        self.normal_queue = make_queue()
        self.have_drained_queues = False
        self.trampoline_enabled = trampoline_enabled

    cdef void enable_trampoline(self):
        self.trampoline_enabled = True

    cdef void disable_trampoline(self):
        self.trampoline_enabled = False

    cdef bint have_items_queued(self):
        return self.is_tick_used or self.have_drained_queues

    cdef void _async_invoke_later(self, SchedulerFn fn, Scheduler scheduler):
        cdef FunctionContainer c = FunctionContainer()
        c.fn = fn
        self.late_queue.push(c)
        self.queue_tick(scheduler)

    cdef void _async_invoke(self, SchedulerFn fn, Scheduler scheduler):
        cdef FunctionContainer c = FunctionContainer()
        c.fn = fn
        self.normal_queue.push(c)
        self.queue_tick(scheduler)

    cdef void _async_settle_promise(self, Promise promise):
        cdef PromiseContainer c = PromiseContainer()
        c.promise = promise
        self.normal_queue.push(c)
        self.queue_tick(promise.get_scheduler())

    cdef void invoke(self, SchedulerFn fn, Scheduler scheduler):
        if self.trampoline_enabled:
            self._async_invoke(fn, scheduler)
        else:
            scheduler.call(fn)

    cdef void settle_promises(self, Promise promise):
        cdef SettlePromisesFn fn = SettlePromisesFn()
        if self.trampoline_enabled:
            self._async_settle_promise(promise)
        else:
            fn.promise = promise
            promise.get_scheduler().call(fn)

    cdef void throw_later(self, Exception reason, Scheduler scheduler):
        cdef RaiseFn fn = RaiseFn()
        fn.reason = reason
        scheduler.call(fn)

    cpdef void fatal_error(self, Exception reason, Scheduler scheduler):
        self.throw_later(reason, scheduler)

    cdef int drain_queue(self, Queue queue) except -1:
        cdef:
            QueueItem fn
            PromiseContainer p
            FunctionContainer f

        while not queue.is_empty():
            fn = queue.shift()
            if isinstance(fn, PromiseContainer):
                p = fn
                p.promise._settle_promises()
                continue
            elif isinstance(fn, FunctionContainer):
                f = fn
                f.fn.call()
            else:
                PyErr_SetString(
                    ValueError, "Unexpected queue item: {}".format(repr(fn))
                )
                return -1
        return 0

    cdef int drain_queue_until_resolved(self, Promise promise) except -1:
        cdef:
            Queue queue = self.normal_queue
            QueueItem fn
            PromiseContainer p
            FunctionContainer f

        while not queue.is_empty():
            if not promise.is_pending():
                return 0
            fn = queue.shift()
            if isinstance(fn, PromiseContainer):
                p = fn
                p.promise._settle_promises()
            elif isinstance(fn, FunctionContainer):
                f = fn
                f.fn.call()
            else:
                PyErr_SetString(
                    ValueError, "Unexpected queue item: {}".format(repr(fn))
                )
                return -1

        self.reset()
        self.have_drained_queues = True
        self.drain_queue(self.late_queue)
        return 0

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
        cdef DrainQueuesFn fn = DrainQueuesFn()
        if not self.is_tick_used:
            self.is_tick_used = True
            fn.localdata = self
            scheduler.call(fn)

    cdef void reset(self):
        self.is_tick_used = False


@cython.final
cdef class Async:
    def __init__(self, bint trampoline_enabled = True):
        self.local = local()
        self.local.data = LocalData(trampoline_enabled)
        self.trampoline_enabled = trampoline_enabled

    cdef LocalData _data(self):
        cdef LocalData data
        if hasattr(self.local, "data"):
            data = self.local.data
        else:
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

    cdef void drain_queue(self, Queue queue):
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

    cpdef bint _TEST_have_drained_queues(self):
        return self._data().have_drained_queues
