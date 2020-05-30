cimport cython

from ..promise cimport Promise
from . cimport Scheduler, SchedulerFn


cdef class SetEvent:
    cdef object event


@cython.final
cdef class ImmediateScheduler(Scheduler):
    pass
