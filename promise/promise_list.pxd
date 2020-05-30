from .promise cimport Promise


cdef class PartialFulfilled:
    cdef PromiseList promise_list
    cdef int i


cdef class PartialRejected:
    cdef PromiseList promise_list
    cdef Promise promise


cdef class PromiseList:
    cdef list _values
    cdef int _length, _total_resolved
    cdef public Promise promise

    cdef void _init_promise(self, Promise values)
    cpdef void _init(self, object values)
    cdef void _iterate(self, list values)
    cdef bint _promise_fulfilled(self, object value, int i)
    cdef bint _promise_rejected(self, Exception reason, Promise promise)
    cdef bint is_resolved(self)
    cdef void _resolve(self, list value)
    cpdef void _reject(self, Exception reason, object traceback=*)
