from promise.promise cimport Promise
from promise.async_ cimport LocalData


cdef class SchedulerFn:
    cdef void call(self) except *


cdef class Scheduler:
    cdef void call(self, SchedulerFn fn)
    cdef int wait(self, Promise promise, object timeout=*) except -1
