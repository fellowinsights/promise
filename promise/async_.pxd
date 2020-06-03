from .promise cimport Promise
from .schedulers.base cimport SchedulerFn, Scheduler


cdef class QueueItem:
    pass


cdef class Queue:
    cdef object inner

    cdef bint is_empty(self)
    cdef void push(self, QueueItem item)
    cdef QueueItem shift(self)


cdef class LocalData:
    cdef public bint is_tick_used, have_drained_queues, trampoline_enabled
    cdef public Queue late_queue, normal_queue

    cdef void enable_trampoline(self)
    cdef void disable_trampoline(self)
    cdef bint have_items_queued(self)
    cdef void _async_invoke_later(self, SchedulerFn fn, Scheduler scheduler)
    cdef void _async_invoke(self, SchedulerFn fn, Scheduler scheduler)
    cdef void _async_settle_promise(self, Promise promise)
    cdef void invoke(self, SchedulerFn fn, Scheduler scheduler)
    cdef void settle_promises(self, Promise promise)
    cdef void throw_later(self, Exception reason, Scheduler scheduler)
    cpdef void fatal_error(self, Exception reason, Scheduler scheduler)
    cdef int drain_queue(self, Queue queue) except -1
    cdef int drain_queue_until_resolved(self, Promise promise) except -1
    cdef void wait(self, Promise promise, object timeout=*)
    cdef void drain_queues(self)
    cdef void queue_tick(self, Scheduler scheduler)
    cdef void reset(self)


cdef class Async:
    cdef object local
    cdef bint trampoline_enabled

    cdef LocalData _data(self)
    cpdef void enable_trampoline(self)
    cpdef void disable_trampoline(self)
    cdef bint have_items_queued(self)
    cdef void _async_invoke_later(self, SchedulerFn fn, Scheduler scheduler)
    cdef void _async_invoke(self, SchedulerFn fn, Scheduler scheduler)
    cdef void _async_settle_promise(self, Promise promise)
    cdef void invoke(self, SchedulerFn fn, Scheduler scheduler)
    cdef public void settle_promises(self, Promise promise)
    cdef void throw_later(self, Exception reason, Scheduler scheduler)
    cpdef void fatal_error(self, Exception reason, Scheduler scheduler)
    cdef void drain_queue(self, Queue queue)
    cdef void drain_queue_until_resolved(self, Promise promise)
    cdef void wait(self, Promise promise, object timeout=*)
    cdef void drain_queues(self)
    cdef void queue_tick(self, Scheduler scheduler)
    cdef void reset(self)
    cpdef bint _TEST_have_drained_queues(self)
