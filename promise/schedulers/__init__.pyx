from promise.promise cimport Promise


cdef class SchedulerFn:
    cdef void call(self) except *:
        return


cdef class Scheduler:
    cdef void call(self, SchedulerFn fn):
        return

    cdef int wait(self, Promise promise, object timeout=None) except -1:
        return 0
