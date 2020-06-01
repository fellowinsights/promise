cimport cython

from ..promise cimport Promise
from .base cimport Scheduler, SchedulerFn


@cython.final
cdef class ImmediateScheduler(Scheduler):
    pass
