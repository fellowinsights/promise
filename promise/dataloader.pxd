cimport cython

from .promise cimport Promise
from .schedulers cimport Scheduler


@cython.final
cdef class LocalData:
    cdef:
        dict promise_cache
        list queue


cdef class DataLoader:
    cdef:
        object threadlocal, _batch_load_fn
        bint batch, cache
        int max_batch_size
        Scheduler _scheduler

    cdef LocalData local_data(self)
    cpdef object get_cache_key(self, object value)
    cpdef object batch_load_fn(self, list ids)
    cdef Promise _load(self, object key)
    cdef void do_resolve_reject(self, key, resolve, reject)
    cpdef Promise load_many(self, object keys)
    cpdef DataLoader clear(self, object key)
    cpdef DataLoader clear_all(self)
    cpdef DataLoader prime(self, key, value)
