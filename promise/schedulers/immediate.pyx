# cython: profile=True
from threading import Event
from cpython.exc cimport PyErr_SetString

from ..promise cimport Promise


cdef class SetEvent:
    def __init__(self, object e):
        self.event = e

    def __call__(self):
        self.event.set()


cdef class ImmediateScheduler:
    cpdef void call(self, fn):
        try:
            fn()
        except:
            pass

    cpdef int wait(self, Promise promise, timeout=None) except -1:
        e = Event()
        on_resolve_or_reject = SetEvent(e)
        promise._then(on_resolve_or_reject, on_resolve_or_reject)
        waited = e.wait(timeout)
        if not waited:
            PyErr_SetString(Exception, "Timeout")
            return -1
        return 0
