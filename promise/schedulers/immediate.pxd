cimport cython

from ..promise cimport Promise
from . cimport Scheduler, SchedulerFn


@cython.final
cdef class ImmediateScheduler(Scheduler):
    pass
