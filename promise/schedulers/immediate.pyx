cimport cython

from threading import Event
from cpython.exc cimport PyErr_SetString

from ..promise cimport Promise
from . cimport Scheduler, SchedulerFn


@cython.final
cdef class ImmediateScheduler(Scheduler):
    cdef void call(self, SchedulerFn fn):
        try:
            fn.call()
        except:
            pass

    cdef int wait(self, Promise promise, timeout=None) except -1:
        cdef:
            object e = Event()
            bint waited

        def on_resolve_or_reject(v):
            e.set()

        promise._then(on_resolve_or_reject, on_resolve_or_reject)
        waited = e.wait(timeout)
        if not waited:
            PyErr_SetString(Exception, "Timeout")
            return -1
        return 0
