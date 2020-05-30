# cython: profile=True

cimport cython

from .promise cimport Promise, is_thenable, try_convert_to_promise


@cython.final
cdef class PartialFulfilled:
    def __init__(self, PromiseList promise_list, int i):
        self.promise_list = promise_list
        self.i = i

    def __call__(self, object value):
        return self.promise_list._promise_fulfilled(value, self.i)


@cython.final
cdef class PartialRejected:
    def __init__(self, PromiseList promise_list, Promise promise):
        self.promise_list = promise_list
        self.promise = promise

    def __call__(self, Exception reason):
        return self.promise_list._promise_rejected(reason, self.promise)


@cython.final
cdef class PromiseList:
    def __init__(self, values):
        self.promise = Promise()
        self._length = self._total_resolved = 0
        self._values = None

        if is_thenable(values):
            self._init_promise(try_convert_to_promise(values)._target())
        else:
            self._init(values)

    cdef void _init_promise(self, Promise values):
        if values.is_fulfilled():
            values = values._value()
        elif values.is_rejected():
            self._reject(values._reason())
            return

        self.promise._is_async_guaranteed = True
        values._then(self._init, self._reject)

    cpdef void _init(self, object values):
        cdef list values_list = list(values)
        if not values_list:
            self._resolve([])
            return
        self._iterate(values_list)

    cdef void _iterate(self, list values):
        cdef bint is_resolved = False
        cdef Promise result = self.promise, \
                maybe_promise
        cdef object val

        self._length = len(values)
        self._values = [None] * self._length

        for i in range(self._length):
            val = values[i]
            if is_thenable(val):
                maybe_promise = try_convert_to_promise(val)._target()
                if maybe_promise.is_pending():
                    maybe_promise._add_callbacks(
                        PartialFulfilled(self, i),
                        PartialRejected(self, maybe_promise),
                        None,
                    )
                    self._values[i] = maybe_promise
                elif maybe_promise.is_fulfilled():
                    is_resolved = self._promise_fulfilled(maybe_promise._value(), i)
                elif maybe_promise.is_rejected():
                    is_resolved = self._promise_rejected(
                        maybe_promise._reason(), promise=maybe_promise
                    )
            else:
                is_resolved = self._promise_fulfilled(val, i)

            if is_resolved:
                break

        if not is_resolved:
            result._is_async_guaranteed = True

    cdef bint _promise_fulfilled(self, object value, int i):
        if self.is_resolved():
            return False
        self._values[i] = value
        self._total_resolved += 1
        if self._total_resolved >= self._length:
            self._resolve(self._values)
            return True
        return False

    cdef bint _promise_rejected(self, Exception reason, Promise promise):
        if self.is_resolved():
            return False
        self._total_resolved += 1
        self._reject(reason, traceback=promise._target()._traceback)
        return True

    cdef bint is_resolved(self):
        return self._values is None

    cdef void _resolve(self, list value):
        assert not self.is_resolved()
        self._values = None
        self.promise._fulfill(value)

    cpdef void _reject(self, Exception reason, object traceback = None):
        assert not self.is_resolved()
        self._values = None
        self.promise._reject_callback(reason, traceback=traceback)
