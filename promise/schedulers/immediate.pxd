from ..promise cimport Promise


cdef class SetEvent:
    cdef object event


cdef class ImmediateScheduler:
    cpdef void call(self, fn)
    cpdef int wait(self, Promise promise, timeout=*) except -1
